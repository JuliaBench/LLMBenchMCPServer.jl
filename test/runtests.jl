using LLMBenchMCPServer
using ClaudeMCPTools
using Test
using JSON

@testset "LLMBenchMCPServer.jl" begin
    include("test_setup_problem.jl")
    include("test_grade_problem.jl")
    include("test_server.jl")
    include("test_example_benchmark.jl")
end