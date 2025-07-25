
export track

import NNlib
import GeoArrays
import ProgressMeter

"""
Compute convolution kernel and the required number of hops per time steps

D: diffusion coefficient
h: spatial resolution
"""
function make_kernel(;D, h, precision)

    # compute 1/Δ, so that 4*D*Δ/h^2 < 1
    n_hops = ceil(Int, 4*D/(h^2*0.99))
    Δ = 1/n_hops
    @assert 4*D*Δ/h^2 < 1

    # convolution kernel
    H = [0 0 0;
         0 1 0;
         0 0 0]

    H = H + D*Δ/h^2 .* [0  1  0;
                        1 -4  1;
                        0  1  0]
    H = precision.(reshape(H, 3, 3, 1, 1))

    H, n_hops
end



"""
Maps time step to the index of `pos_filter` and `pos_smoother`
"""
time2index(t, tsave) = findfirst(==(t), tsave)


# ---
# filter algorithm

function run_filter(pos_init, H,
                    bathymetry,
                    observations, observation_models,
                    distances;
                    hops_per_step,
                    tsave=1:100,
                    show_progressbar)

    tmax = maximum(tsave)

    pos_init ./= sum(pos_init)
    nx, ny = size(bathymetry)[1:2]

    pos = similar(H, nx, ny, 1, length(tsave))

    pos_tmp = similar(H, nx, ny, 1, 1)
    pos_tmp[:,:,1,1] = pos_init
    pos[:,:,1,1] .= pos_tmp[:,:,1,1]


    pmeter = ProgressMeter.Progress(tmax - 1; desc = "Filtering...:",
                                    output = stderr, enabled = show_progressbar)

    log_p = zeros(eltype(H), length(tsave))
    log_p_acc = zero(eltype(H))

    for t in 2:tmax

        # --- solve Fokker-Plank
        for k in 1:hops_per_step
            pos_tmp[:,:,1,1] = NNlib.conv(pos_tmp[:,:,1:1,1:1], H, pad=1)
        end

        # you can't be on land (negative bathymetry)
        pos_tmp .= ifelse.(bathymetry .< 0, 0, pos_tmp)

        # --- add observations
        for k  in eachindex(observations)
            p_obs = observation_models[k]
            signals = observations[k]
            pos_tmp[:,:,1,1] .*= p_obs.(Ref(signals), Ref(t), bathymetry, view(distances, :,:,k))
        end

        # --- normalize
        Z = sum(pos_tmp[:,:,1,1])
        isfinite(Z) ||
            error("No solution at time point $(t)! Check for data incompatibilities.")
        pos_tmp[:,:,1,1] .= pos_tmp[:,:,1,1] ./ Z

        log_p_acc += log(Z)

        # --- save results
        if t in tsave
            pos[:,:,1,time2index(t, tsave)] .= pos_tmp[:,:,1,1]
            log_p[time2index(t, tsave)] = log_p_acc
            log_p_acc = zero(eltype(H))
        end

        ProgressMeter.next!(pmeter)
    end

    return pos, log_p
end


# ---
# smoothing algorithm


"""
Define division by zero as equal to zero.
"""
function divzero(a, b)
    if iszero(b)
        zero(a/b)
    else
        # if b < abs(a) / typemax(a) we can get Inf
        min(a/b, floatmax(b))
    end
end


function run_smoother(pos_filter, H,
                      bathymetry,
                      observations, observation_models,
                      distances;
                      hops_per_step,
                      tsave=1:100,
                      show_progressbar)

    ext = Base.get_extension(@__MODULE__, :CUDAExt)

    tmax = maximum(tsave)
    n_tsave = length(tsave)

    nx, ny = size(pos_filter)[1:2]

    # hold smoothed results, P(s_t | y_{1:T})
    pos_smoother = similar(pos_filter)
    pos_smoother_tmp = similar(pos_filter, nx, ny, 1)

    pos_smoother_tmp[:,:,1] .= pos_smoother[:,:,1,end] .= pos_filter[:,:,1,end]

    # distribution of resdence time over all time steps
    residence_dist = similar(pos_filter, nx, ny)
    residence_dist[:,:] .= pos_filter[:,:,1,end]

    pmeter = ProgressMeter.Progress(n_tsave - 1; desc = "Smoothing...:",
                                    output = stderr, enabled = show_progressbar)

    # jth jump back in time
    for j in (n_tsave-1):-1:1

        tsave_jump = tsave[j]:1:tsave[j+1]    # "internal", reconstructed time-steps

        # -----------
        # 1) recompute all filter steps between j and j+1

        # holds reconstructed filter results
        pos_filter_jump = similar(pos_filter, nx, ny, 1, length(tsave_jump))          # P(s_t | y_{1:t})
        pos_filter_jump_no_obs = similar(pos_filter, nx, ny, 1, length(tsave_jump))   # P(s_{t+1} | y_{1:t})

        pos_filter_jump[:,:,1,1] .= pos_filter_jump_no_obs[:,:,1,1] .= pos_filter[:,:,1,time2index(tsave_jump[1], tsave)]


        for (i,t) in enumerate(tsave_jump[1:(end-1)])

            pos_filter_jump[:,:,1,i+1] .= pos_filter_jump[:,:,1,i]

            # --- solve Fokker-Plank
            for k in 1:hops_per_step
                pos_filter_jump[:,:,1,(i+1):(i+1)] = NNlib.conv(pos_filter_jump[:,:,1:1,(i+1):(i+1)], H, pad=1)
            end

            # you can't be on land (negative bathymetry)
            pos_filter_jump .= ifelse.(bathymetry .< 0, 0, pos_filter_jump)

            # --- save P(s_{t+1} | y_{1:t})
            pos_filter_jump_no_obs[:,:,1,i+1] .= pos_filter_jump[:,:,1,i+1]

            # --- add observations
            for k  in eachindex(observations)
                p_obs = observation_models[k]
                signals = observations[k]
                pos_filter_jump[:,:,1,i+1] .*= p_obs.(Ref(signals), Ref(t), bathymetry, view(distances, :,:,k))
            end

            # --- normalize
            Z = sum(pos_filter_jump[:,:,1,i+1])
            isfinite(Z) ||
                error("No solution at time point $(t)!")
            pos_filter_jump[:,:,1,i+1] .= pos_filter_jump[:,:,1,i+1] ./ Z


        end

        # -----------
        # 2) backward smoothing

        pos_smoother_tmp[:,:,1,1] .= pos_smoother[:,:,1,time2index(tsave_jump[end], tsave)]


        for (i, t) in enumerate(reverse(tsave_jump)[2:end])

            idx = length(tsave_jump) - i + 1 # index of pos_filter_jump

            # treat division by zero as special case
            pos_smoother_tmp[:,:,1,1] .= divzero.(pos_smoother_tmp[:,:,1,1], pos_filter_jump_no_obs[:,:,1,idx])


            # --- solve Fokker-Plank backwards
            # K = rot180(H) = H if no advections
            for k in 1:hops_per_step
                pos_smoother_tmp[:,:,1,1] = NNlib.conv(pos_smoother_tmp[:,:,1:1,1:1], H, pad=1)
            end

            # you can't be on land (negative bathymetry)
            pos_smoother_tmp .= ifelse.(bathymetry .< 0, 0, pos_smoother_tmp)

            pos_smoother_tmp[:,:,1,1] .=  pos_filter_jump[:,:,1,idx-1] .* pos_smoother_tmp[:,:,1,1] #.+ eps(0f0)
            pos_smoother_tmp[:,:,1,1] ./= sum(pos_smoother_tmp[:,:,1,1])

            residence_dist .+= pos_smoother_tmp[:,:,1,1]

            # --- save
            if t in tsave
                pos_smoother[:,:,1,time2index(t, tsave)] .= pos_smoother_tmp[:,:,1,1]
            end

        end

        ProgressMeter.next!(pmeter)

    end

    # normalize
    residence_dist ./= sum(residence_dist)

    return (pos_smoother, residence_dist)
end
