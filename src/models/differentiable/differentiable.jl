
"""
Base type for differentiable models.
"""
abstract type AbstractDifferentiableModel <: AbstractFittedModel end

"""
Base type for differentiable models written in pure Julia.
"""
abstract type AbstractDifferentiableJuliaModel <: AbstractDifferentiableModel end

include("flux_mlp.jl")
include("flux_ensemble.jl")
include("laplace_redux.jl")
