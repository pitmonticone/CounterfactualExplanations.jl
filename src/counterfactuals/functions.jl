using Flux
using MLUtils
using SliceMap
using Statistics
using StatsBase

"""
A struct that collects all information relevant to a specific counterfactual explanation for a single individual.
"""
mutable struct CounterfactualExplanation <: AbstractCounterfactualExplanation
    x::AbstractArray
    target::RawTargetType
    target_encoded::EncodedTargetType
    s′::AbstractArray
    data::DataPreprocessing.CounterfactualData
    M::Models.AbstractFittedModel
    generator::Generators.AbstractGenerator
    generative_model_params::NamedTuple
    params::Dict
    search::Union{Dict,Nothing}
    convergence::Dict
    num_counterfactuals::Int
    initialization::Symbol
end

"""
    function CounterfactualExplanation(;
        x::AbstractArray,
        target::RawTargetType,
        data::CounterfactualData,
        M::Models.AbstractFittedModel,
        generator::Generators.AbstractGenerator,
        max_iter::Int = 100,
        num_counterfactuals::Int = 1,
        initialization::Symbol = :add_perturbation,
        generative_model_params::NamedTuple = (;),
        min_success_rate::AbstractFloat=0.99,
    )

Outer method to construct a `CounterfactualExplanation` structure.
"""
function CounterfactualExplanation(;
    x::AbstractArray,
    target::RawTargetType,
    data::CounterfactualData,
    M::Models.AbstractFittedModel,
    generator::Generators.AbstractGenerator,
    num_counterfactuals::Int=1,
    initialization::Symbol=:add_perturbation,
    generative_model_params::NamedTuple=(;),
    max_iter::Int=100,
    decision_threshold::AbstractFloat=0.5,
    gradient_tol::AbstractFloat=parameters[:τ],
    min_success_rate::AbstractFloat=parameters[:min_success_rate],
    converge_when::Symbol=:decision_threshold
)

    # Assertions:
    @assert any(predict_label(M, data) .== target) "You model `M` never predicts the target value `target` for any of the samples contained in `data`. Are you sure the model is correctly specified?"
    @assert 0.0 < min_success_rate <= 1.0 "Minimum success rate should be ∈ [0.0,1.0]."
    @assert converge_when ∈ [:decision_threshold, :generator_conditions, :max_iter]

    # Factual:
    x = typeof(x) == Int ? select_factual(data, x) : x

    # Target:
    target_encoded = data.output_encoder(target)

    # Initial Parameters:
    params = Dict{Symbol,Any}(
        :mutability => DataPreprocessing.mutability_constraints(data),
        :latent_space => generator.latent_space
    )
    ids = findall(predict_label(M, data) .== target)
    n_candidates = minimum([size(data.y, 2), 1000])
    candidates = select_factual(data, rand(ids, n_candidates))
    params[:potential_neighbours] = reduce(hcat, map(x -> x[1], collect(candidates)))

    # Convergence Parameters:
    convergence = Dict(
        :max_iter => max_iter,
        :decision_threshold => decision_threshold,
        :gradient_tol => gradient_tol,
        :min_success_rate => min_success_rate,
        :converge_when => converge_when,
    )

    # Instantiate: 
    counterfactual_explanation = CounterfactualExplanation(
        x,
        target,
        target_encoded,
        x,
        data,
        deepcopy(M),
        deepcopy(generator),
        generative_model_params,
        params,
        nothing,
        convergence,
        num_counterfactuals,
        initialization,
    )

    # Initialization:
    adjust_shape!(counterfactual_explanation)                                           # adjust shape to specified number of counterfactuals
    counterfactual_explanation.s′ = encode_state(counterfactual_explanation)            # encode the counterfactual state
    counterfactual_explanation.s′ = initialize_state(counterfactual_explanation)        # initialize the counterfactual state

    # Initialize search:
    counterfactual_explanation.search = Dict(
        :iteration_count => 0,
        :times_changed_features =>
            zeros(size(decode_state(counterfactual_explanation))),
        :path => [counterfactual_explanation.s′],
        :terminated =>
            threshold_reached(counterfactual_explanation, counterfactual_explanation.x),
        :converged => converged(counterfactual_explanation),
    )

    # Check for redundancy:
    if terminated(counterfactual_explanation)
        @info "Factual already in target class and probability exceeds threshold γ."
    end

    return counterfactual_explanation

end

# 1.) Convenience methods:
"""
    output_dim(counterfactual_explanation::CounterfactualExplanation)

A convenience method that returns the output dimension of the predictive model.
"""
output_dim(counterfactual_explanation::CounterfactualExplanation) =
    size(Models.probs(counterfactual_explanation.M, counterfactual_explanation.x))[1]

"""
    guess_loss(counterfactual_explanation::CounterfactualExplanation)

Guesses the loss function to be used for the counterfactual search in case `likelihood` field is specified for the [`AbstractFittedModel`](@ref) instance and no loss function was explicitly declared for [`AbstractGenerator`](@ref) instance.
"""
function guess_loss(counterfactual_explanation::CounterfactualExplanation)
    if :likelihood in fieldnames(typeof(counterfactual_explanation.M))
        if counterfactual_explanation.M.likelihood == :classification_binary
            loss_fun = Objectives.logitbinarycrossentropy
        elseif counterfactual_explanation.M.likelihood == :classification_multi
            loss_fun = Objectives.logitcrossentropy
        else
            loss_fun = Flux.Losses.mse
        end
    else
        loss_fun = nothing
    end
    return loss_fun
end

# 2.) Initialisation
"""
    adjust_shape(
        counterfactual_explanation::CounterfactualExplanation, 
        x::AbstractArray
    )

A convenience method that adjusts the dimensions of `x`.
"""
function adjust_shape(
    counterfactual_explanation::CounterfactualExplanation,
    x::AbstractArray,
)

    size_ =
        Int.(
            vcat(
                ones(maximum([ndims(x), 2])),
                counterfactual_explanation.num_counterfactuals,
            )
        )
    s′ = copy(x)
    s′ = repeat(x, outer=size_)

    return s′

end

"""
    adjust_shape!(counterfactual_explanation::CounterfactualExplanation)

A convenience method that adjusts the dimensions of the counterfactual state and related fields.
"""
function adjust_shape!(counterfactual_explanation::CounterfactualExplanation)

    # Dimensionality:
    x = deepcopy(counterfactual_explanation.x)
    s′ = adjust_shape(counterfactual_explanation, x)      # augment to account for specified number of counterfactuals
    counterfactual_explanation.s′ = s′
    target_encoded = counterfactual_explanation.target_encoded
    counterfactual_explanation.target_encoded =
        adjust_shape(counterfactual_explanation, target_encoded)

    # Parameters:
    params = counterfactual_explanation.params
    params[:mutability] = adjust_shape(counterfactual_explanation, params[:mutability])      # augment to account for specified number of counterfactuals
    counterfactual_explanation.params = params
end

"""
    function encode_state(
        counterfactual_explanation::CounterfactualExplanation, 
        x::Union{AbstractArray,Nothing} = nothing,
    )

Applies all required encodings to `x`:

1. If applicable, it maps `x` to the latent space learned by the generative model.
2. If and where applicable, it rescales features. 

Finally, it returns the encoded state variable.
"""
function encode_state(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)

    # Unpack:
    s′ = isnothing(x) ? deepcopy(counterfactual_explanation.s′) : x
    data = counterfactual_explanation.data

    # Latent space:
    if counterfactual_explanation.params[:latent_space]
        s′ = map_to_latent(counterfactual_explanation, s′)
        return s′
    end

    # Standardize data unless latent space:
    if !counterfactual_explanation.params[:latent_space]
        dt = data.dt
        idx = transformable_features(data)
        SliceMap.slicemap(s′, dims=(1, 2)) do s
            _s = s[idx, :]
            StatsBase.transform!(dt, _s)
            s[idx, :] = _s
        end
        return s′
    end

end

"""
    wants_latent_space(
        counterfactual_explanation::CounterfactualExplanation, 
        x::Union{AbstractArray,Nothing} = nothing,
    )   

A convenience function that checks if latent space search is applicable.
"""
function wants_latent_space(counterfactual_explanation::CounterfactualExplanation)

    # Unpack:
    latent_space = counterfactual_explanation.params[:latent_space]

    # If threshold is already reached, training GM is redundant:
    latent_space =
        latent_space &&
        !threshold_reached(counterfactual_explanation, counterfactual_explanation.x)

    return latent_space

end

@doc raw"""
   function map_to_latent(
        counterfactual_explanation::CounterfactualExplanation,
        x::Union{AbstractArray,Nothing}=nothing,
    ) 

Maps `x` from the feature space $\mathcal{X}$ to the latent space learned by the generative model.
"""
function map_to_latent(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)

    # Unpack:
    s′ = isnothing(x) ? deepcopy(counterfactual_explanation.s′) : x
    data = counterfactual_explanation.data
    generator = counterfactual_explanation.generator

    if counterfactual_explanation.params[:latent_space]
        @info "Searching in latent space using generative model."
        generative_model = DataPreprocessing.get_generative_model(
            data;
            counterfactual_explanation.generative_model_params...
        )
        # map counterfactual to latent space: s′=z′∼p(z|x)
        s′, _, _ = GenerativeModels.rand(generative_model.encoder, s′)
    end

    return s′

end

"""
    function decode_state(
        counterfactual_explanation::CounterfactualExplanation,
        x::Union{AbstractArray,Nothing}=nothing,
    )

Applies all the applicable decoding functions:

1. If applicable, map the state variable back from the latent space to the feature space.
2. If and where applicable, inverse-transform features.
3. Reconstruct all categorical encodings.

Finally, the decoded counterfactual is returned.
"""
function decode_state(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)

    # Unpack:
    s′ = isnothing(x) ? deepcopy(counterfactual_explanation.s′) : x
    data = counterfactual_explanation.data

    # Latent space:
    if counterfactual_explanation.params[:latent_space]
        s′ = map_from_latent(counterfactual_explanation, s′)
    end

    # Standardization:
    if !counterfactual_explanation.params[:latent_space]

        dt = data.dt

        # Continuous:
        idx = transformable_features(data)
        SliceMap.slicemap(s′, dims=(1, 2)) do s
            _s = s[idx, :]
            StatsBase.reconstruct!(dt, _s)
            s[idx, :] = _s
        end

    end

    # Categorical:
    s′ = reconstruct_cat_encoding(counterfactual_explanation, s′)

    return s′

end

"""
    map_from_latent(
        counterfactual_explanation::CounterfactualExplanation,
        x::Union{AbstractArray,Nothing}=nothing,
    )

Maps the state variable back from the latent space to the feature space.
"""
function map_from_latent(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)

    # Unpack:
    s′ = isnothing(x) ? deepcopy(counterfactual_explanation.s′) : x
    data = counterfactual_explanation.data

    # Latent space:
    if counterfactual_explanation.params[:latent_space]
        generative_model = data.generative_model
        if !isnothing(generative_model)
            # NOTE! This is not very clean, will be improved.
            if generative_model.params.nll == Flux.Losses.logitbinarycrossentropy
                s′ = Flux.σ.(generative_model.decoder(s′))
            else
                s′ = generative_model.decoder(s′)
            end
        end
    end

    return s′

end

"""
    reconstruct_cat_encoding(
        counterfactual_explanation::CounterfactualExplanation,
        x::Union{AbstractArray,Nothing}=nothing,
    )

Reconstructs all categorical encodings. See [`DataPreprocessing.reconstruct_cat_encoding`](@ref) for details.
"""
function reconstruct_cat_encoding(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)
    # Unpack:
    s′ = isnothing(x) ? deepcopy(counterfactual_explanation.s′) : x
    data = counterfactual_explanation.data

    s′ = SliceMap.slicemap(s′, dims=(1, 2)) do s
        s_encoded = DataPreprocessing.reconstruct_cat_encoding(data, s)
        s = reshape(s_encoded, size(s)...)
        return s
    end

    return s′
end

"""
    initialize_state(counterfactual_explanation::CounterfactualExplanation)

Initializes the starting point for the factual(s):
    
1. If `counterfactual_explanation.initialization` is set to `:identity` or counterfactuals are searched in a latent space, then nothing is done.
2. If `counterfactual_explanation.initialization` is set to `:add_perturbation`, then a random perturbation is added to the factual following following Slack (2021): https://arxiv.org/abs/2106.02666. The authors show that this improves adversarial robustness.
"""
function initialize_state(counterfactual_explanation::CounterfactualExplanation)

    @assert counterfactual_explanation.initialization ∈ [:identity, :add_perturbation]

    s′ = counterfactual_explanation.s′
    data = counterfactual_explanation.data

    # No perturbation:
    if counterfactual_explanation.initialization == :identity
        return s′
    end

    # If latent space, initial point is random anyway:
    if counterfactual_explanation.params[:latent_space]
        return s′
    end

    # Add random perturbation following Slack (2021): https://arxiv.org/abs/2106.02666
    if counterfactual_explanation.initialization == :add_perturbation
        s′ = SliceMap.slicemap(s′, dims=(1, 2)) do s
            Δs′ = randn(eltype(s), size(s, 1)) * convert(eltype(s), 0.1)
            Δs′ = apply_mutability(counterfactual_explanation, Δs′)
            s .+ Δs′
        end 
    end

    return s′

end

# 3.) Information about CE
"""
    factual(counterfactual_explanation::CounterfactualExplanation)

A convenience method to retrieve the factual `x`.
"""
factual(counterfactual_explanation::CounterfactualExplanation) =
    counterfactual_explanation.x

"""
    factual_probability(counterfactual_explanation::CounterfactualExplanation)

A convenience method to compute the class probabilities of the factual.
"""
factual_probability(counterfactual_explanation::CounterfactualExplanation) =
    Models.probs(counterfactual_explanation.M, counterfactual_explanation.x)

"""
    factual_label(counterfactual_explanation::CounterfactualExplanation)  

A convenience method to get the predicted label associated with the factual.
"""
function factual_label(counterfactual_explanation::CounterfactualExplanation)
    M = counterfactual_explanation.M
    counterfactual_data = counterfactual_explanation.data
    y = predict_label(M, counterfactual_data, factual(counterfactual_explanation))
    return y
end

"""
    counterfactual(counterfactual_explanation::CounterfactualExplanation)

A convenience method that returns the counterfactual.
"""
counterfactual(counterfactual_explanation::CounterfactualExplanation) =
    decode_state(counterfactual_explanation)

"""
    counterfactual_probability(counterfactual_explanation::CounterfactualExplanation)

A convenience method that computes the class probabilities of the counterfactual.
"""
counterfactual_probability(counterfactual_explanation::CounterfactualExplanation) =
    Models.probs(counterfactual_explanation.M, counterfactual(counterfactual_explanation))

"""
    counterfactual_label(counterfactual_explanation::CounterfactualExplanation) 

A convenience method that returns the predicted label of the counterfactual.
"""
function counterfactual_label(counterfactual_explanation::CounterfactualExplanation)
    M = counterfactual_explanation.M
    counterfactual_data = counterfactual_explanation.data
    y = SliceMap.slicemap(
        x -> permutedims([predict_label(M, counterfactual_data, x)[1]]),
        counterfactual(counterfactual_explanation),
        dims=(1, 2),
    )
    return y
end

"""
    target_probs(
        counterfactual_explanation::CounterfactualExplanation,
        x::Union{AbstractArray,Nothing}=nothing,
    )

Returns the predicted probability of the target class for `x`. If `x` is `nothing`, the predicted probability corresponding to the counterfactual value is returned.
"""
function target_probs(
    counterfactual_explanation::CounterfactualExplanation,
    x::Union{AbstractArray,Nothing}=nothing,
)

    data = counterfactual_explanation.data
    likelihood = counterfactual_explanation.data.likelihood
    p =
        !isnothing(x) ? Models.probs(counterfactual_explanation.M, x) :
        counterfactual_probability(counterfactual_explanation)
    target = counterfactual_explanation.target
    target_idx = get_target_index(data.y_levels, target)
    if likelihood == :classification_binary
        if target_idx == 2
            p_target = p
        else
            p_target = 1 .- p
        end
    else
        p_target = SliceMap.slicemap(_p -> permutedims([_p[target_idx]]), p, dims=(1, 2))
    end
    return p_target
end

# 4.) Search related methods:
"""
    path(counterfactual_explanation::CounterfactualExplanation)

A convenience method that returns the entire counterfactual path.
"""
function path(counterfactual_explanation::CounterfactualExplanation; feature_space=true)
    path = deepcopy(counterfactual_explanation.search[:path])
    if feature_space
        path = [decode_state(counterfactual_explanation, z) for z ∈ path]
    end
    return path
end

"""
    counterfactual_probability_path(counterfactual_explanation::CounterfactualExplanation)

Returns the counterfactual probabilities for each step of the search.
"""
function counterfactual_probability_path(
    counterfactual_explanation::CounterfactualExplanation,
)
    M = counterfactual_explanation.M
    p = map(
        X -> mapslices(x -> probs(M, x), X, dims=(1, 2)),
        path(counterfactual_explanation),
    )
    return p
end

"""
    counterfactual_label_path(counterfactual_explanation::CounterfactualExplanation)

Returns the counterfactual labels for each step of the search.
"""
function counterfactual_label_path(counterfactual_explanation::CounterfactualExplanation)
    counterfactual_data = counterfactual_explanation.data
    M = counterfactual_explanation.M
    ŷ = map(
        X -> mapslices(x -> predict_label(M, counterfactual_data, x), X, dims=(1, 2)),
        path(counterfactual_explanation),
    )
    return ŷ
end

"""
    target_probs_path(counterfactual_explanation::CounterfactualExplanation)

Returns the target probabilities for each step of the search.
"""
function target_probs_path(counterfactual_explanation::CounterfactualExplanation)
    X = path(counterfactual_explanation)
    P = map(
        X -> mapslices(x -> target_probs(counterfactual_explanation, x), X, dims=(1, 2)),
        X,
    )
    return P
end

"""
    embed_path(counterfactual_explanation::CounterfactualExplanation)

Helper function that embeds path into two dimensions for plotting.
"""
function embed_path(counterfactual_explanation::CounterfactualExplanation)
    data_ = counterfactual_explanation.data
    path_ = MLUtils.stack(path(counterfactual_explanation); dims=1)
    path_embedded = mapslices(X -> DataPreprocessing.embed(data_, X'), path_, dims=(1, 2))
    path_embedded = unstack(path_embedded, dims=2)
    return path_embedded
end

"""
    apply_mutability(
        counterfactual_explanation::CounterfactualExplanation,
        Δs′::AbstractArray,
    )

A subroutine that applies mutability constraints to the proposed vector of feature perturbations.
"""
function apply_mutability(
    counterfactual_explanation::CounterfactualExplanation,
    Δs′::AbstractArray,
)

    if counterfactual_explanation.params[:latent_space]
        if isnothing(counterfactual_explanation.search)
            @warn "Mutability constraints not currently implemented for latent space search."
        end
        return Δs′
    end

    mutability = counterfactual_explanation.params[:mutability]
    # Helper functions:
    both(x) = x
    increase(x) = ifelse(x < 0.0, 0.0, x)
    decrease(x) = ifelse(x > 0.0, 0.0, x)
    none(x) = 0.0
    cases = (both=both, increase=increase, decrease=decrease, none=none)

    # Apply:
    Δs′ = map((case, s) -> getfield(cases, case)(s), mutability, Δs′)

    return Δs′

end

"""
    apply_domain_constraints!(counterfactual_explanation::CounterfactualExplanation)

Wrapper function that applies underlying domain constraints.
"""
function apply_domain_constraints!(counterfactual_explanation::CounterfactualExplanation)

    if !wants_latent_space(counterfactual_explanation)
        s′ = counterfactual_explanation.s′
        counterfactual_explanation.s′ =
            DataPreprocessing.apply_domain_constraints(counterfactual_explanation.data, s′)
    end

end

# 5.) Convergence related methods:
"""
    terminated(counterfactual_explanation::CounterfactualExplanation)

A convenience method to determine if the counterfactual search has terminated.
"""
function terminated(counterfactual_explanation::CounterfactualExplanation)
    converged(counterfactual_explanation) || steps_exhausted(counterfactual_explanation)
end

"""
    converged(counterfactual_explanation::CounterfactualExplanation)

A convenience method to determine if the counterfactual search has converged. The search is considered to have converged only if the counterfactual is valid.
"""
function converged(counterfactual_explanation::CounterfactualExplanation)

    if counterfactual_explanation.convergence[:converge_when] == :decision_threshold
        conv = threshold_reached(counterfactual_explanation)
    elseif counterfactual_explanation.convergence[:converge_when] == :generator_conditions
        conv = threshold_reached(counterfactual_explanation) && 
            Generators.conditions_satisfied(
                counterfactual_explanation.generator,
                counterfactual_explanation,
            )
    elseif counterfactual_explanation.convergence[:converge_when] == :max_iter
        conv = false
    end

    return conv
end

"""
    threshold_reached(counterfactual_explanation::CounterfactualExplanation)

A convenience method that determines if the predefined threshold for the target class probability has been reached.
"""
function threshold_reached(counterfactual_explanation::CounterfactualExplanation)
    γ = counterfactual_explanation.convergence[:decision_threshold]
    success_rate = sum(target_probs(counterfactual_explanation) .>= γ) / counterfactual_explanation.num_counterfactuals 
    return success_rate > counterfactual_explanation.convergence[:min_success_rate]
end

"""
    threshold_reached(counterfactual_explanation::CounterfactualExplanation, x::AbstractArray)

A convenience method that determines if the predefined threshold for the target class probability has been reached for a specific sample `x`.
"""
function threshold_reached(
    counterfactual_explanation::CounterfactualExplanation,
    x::AbstractArray
)
    γ = counterfactual_explanation.convergence[:decision_threshold]
    success_rate = sum(target_probs(counterfactual_explanation, x) .>= γ) / counterfactual_explanation.num_counterfactuals
    return success_rate > counterfactual_explanation.convergence[:min_success_rate]
end

"""
    steps_exhausted(counterfactual_explanation::CounterfactualExplanation) 

A convenience method that checks if the number of maximum iterations has been exhausted.
"""
steps_exhausted(counterfactual_explanation::CounterfactualExplanation) =
    counterfactual_explanation.search[:iteration_count] ==
    counterfactual_explanation.convergence[:max_iter]

"""
    total_steps(counterfactual_explanation::CounterfactualExplanation)

A convenience method that returns the total number of steps of the counterfactual search.
"""
total_steps(counterfactual_explanation::CounterfactualExplanation) =
    counterfactual_explanation.search[:iteration_count]

# UPDATES
"""
    update!(counterfactual_explanation::CounterfactualExplanation) 

An important subroutine that updates the counterfactual explanation. It takes a snapshot of the current counterfactual search state and passes it to the generator. Based on the current state the generator generates perturbations. Various constraints are then applied to the proposed vector of feature perturbations. Finally, the counterfactual search state is updated.
"""
function update!(counterfactual_explanation::CounterfactualExplanation)

    # Generate peturbations:
    Δs′ = Generators.generate_perturbations(
        counterfactual_explanation.generator,
        counterfactual_explanation,
    )
    Δs′ = apply_mutability(counterfactual_explanation, Δs′)         # mutability constraints
    s′ = counterfactual_explanation.s′ + Δs′                        # new proposed state

    # Updates:
    counterfactual_explanation.s′ = s′                                                  # update counterfactual
    _times_changed = reshape(
        decode_state(counterfactual_explanation, Δs′) .!= 0,
        size(counterfactual_explanation.search[:times_changed_features]),
    )
    counterfactual_explanation.search[:times_changed_features] += _times_changed        # update number of times feature has been changed
    counterfactual_explanation.search[:mutability] = Generators.mutability_constraints(
        counterfactual_explanation.generator,
        counterfactual_explanation,
    )
    counterfactual_explanation.search[:iteration_count] += 1                            # update iteration counter   
    counterfactual_explanation.search[:path] =
        [counterfactual_explanation.search[:path]..., counterfactual_explanation.s′]
    counterfactual_explanation.search[:converged] = converged(counterfactual_explanation)
    counterfactual_explanation.search[:terminated] = terminated(counterfactual_explanation)

end

"""
    get_meta(counterfactual_explanation::CounterfactualExplanation)

Returns meta data for a counterfactual explanation.
"""
function get_meta(counterfactual_explanation::CounterfactualExplanation)
    meta_data = Dict(
        :model => Symbol(counterfactual_explanation.M),
        :generator => Symbol(counterfactual_explanation.generator),
    )
    return meta_data
end

function Base.show(io::IO, z::CounterfactualExplanation)

    println(io, "")
    if z.search[:iteration_count] > 0
        if isnothing(z.convergence[:decision_threshold])
            p_path = target_probs_path(z)
            n_reached = findall([all(p .>= z.convergence[:decision_threshold]) for p in p_path])
            if length(n_reached) > 0
                printstyled(
                    io,
                    "Threshold reached: $(all(threshold_reached(z)) ? "✅"  : "❌")",
                    bold=true,
                )
                print(" after $(first(n_reached)) steps.\n")
            end
            printstyled(io, "Convergence: $(converged(z) ? "✅"  : "❌")", bold=true)
            print(" after $(total_steps(z)) steps.\n")
        else
            printstyled(io, "Convergence: $(converged(z) ? "✅"  : "❌")", bold=true)
            print(" after $(total_steps(z)) steps.\n")
        end
    end

end
