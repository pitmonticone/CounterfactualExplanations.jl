using CounterfactualExplanations
using Documenter

include("setup_docs.jl")

DocMeta.setdocmeta!(
    CounterfactualExplanations,
    :DocTestSetup,
    :(setup_docs);
    recursive = true,
)

makedocs(;
    modules=[CounterfactualExplanations],
    authors="Patrick Altmeyer",
    repo="https://github.com/juliatrustworthyai/CounterfactualExplanations.jl/blob/{commit}{path}#{line}",
    sitename="CounterfactualExplanations.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://juliatrustworthyai.github.io/CounterfactualExplanations.jl",
        assets=String[]
    ),
    pages=[
        "🏠 Home" => "index.md",
        "🫣 Tutorials" => [
            "Overview" => "tutorials/index.md",
            "Whiste-Stop Tour" => "tutorials/whistle_stop.md",
            "Handling Data" => "tutorials/data_preprocessing.md",
            "Data Catalogue" => "tutorials/data_catalogue.md",
            "Handling Models" => "tutorials/models.md",
            "Model Catalogue" => "tutorials/model_catalogue.md",
            "Handing Generators" => "tutorials/generators.md",
            "Evaluating Explanations" => "tutorials/evaluation.md",
            "Benchmarking Explanations" => "tutorials/benchmarking.md",
        ],
        "🤓 Explanation" => [
            "Overview" => "explanation/index.md",
            "Package Architecture" => "explanation/architecture.md",
            "Generators" => [
                "Overview" => "explanation/generators/overview.md", 
                "Generic" => "explanation/generators/generic.md", 
                "Gravitational" => "explanation/generators/gravitational.md", 
                "REVISE" => "explanation/generators/revise.md",
                "DiCE" => "explanation/generators/dice.md",
                "ClaPROAR" => "explanation/generators/clap_roar.md", 
                "Greedy" => "explanation/generators/greedy.md", 
            ],
            "Optimisers" => [
                "Overview" => "explanation/optimisers/overview.md", 
                "JSMA" => "explanation/optimisers/jsma.md", 
            ],
            "Categorical Features" => "explanation/categorical.md",
            # "Loss functions" => "explanation/loss.md",
        ],
        "🫡 How-To ..." => [
            "Overview" => "how_to_guides/index.md",
            "... add custom generators" => "how_to_guides/custom_generators.md",
            "... add custom models" => "how_to_guides/custom_models.md",
            # "... explain R/Python models" => "how_to_guides/interop.md",
        ],
        "🧐 Reference" => "reference.md",
        "🛠 Contribute" => "contribute.md",
        "📚 Additional Resources" => "assets/resources.md",
    ]
)

deploydocs(; 
    repo = "github.com/JuliaTrustworthyAI/CounterfactualExplanations.jl", 
    devbranch = "main"
)
