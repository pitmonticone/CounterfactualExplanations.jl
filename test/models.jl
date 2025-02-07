using CounterfactualExplanations
using CounterfactualExplanations.Models
using Flux
using LinearAlgebra
using MLUtils
using Random

@testset "Models for synthetic data" begin
    for (key, value) ∈ synthetic
        name = string(key)
        @testset "$name" begin
            X = value[:data].X
            for (likelihood, model) ∈ value[:models]
                name = string(likelihood)
                @testset "$name" begin
                    @testset "Matrix of inputs" begin
                        @test size(logits(model[:model], X))[2] == size(X,2)
                        @test size(probs(model[:model], X))[2] == size(X,2)
                    end
                    @testset "Vector of inputs" begin
                        @test size(logits(model[:model], X[:, 1]), 2) == 1
                        @test size(probs(model[:model], X[:, 1]), 2) == 1
                    end
                end
            end
        end
    end
end
