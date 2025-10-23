# Create a test module using LLMBenchSimple's @bench macro
module SimpleBenchModule
    using LLMBenchSimple

    # Define benchmarks using @bench macro with proper prompt syntax
    @bench "math1" begin
        promptval"What is 5 + 3?" == 8
    end

    @bench "math2" begin
        promptval"What is 10 - 4?" == 6
    end
end # module

using LLMBenchMCPServer
using ClaudeMCPTools
using JSON

@testset "LLMBenchSimple Integration" begin
    @testset "Module with LLMBenchSimple functions" begin
        # Get the module
        mod = Main.SimpleBenchModule

        mktempdir() do workdir
                # Test setup_problem with empty problem_id
                description = mod.setup_problem(workdir, "")
                @test !isempty(description)
                # Should list available problems or give an error message

                # Test setup_problem for specific problem
                description = mod.setup_problem(workdir, "math1")
                @test occursin("5 + 3", description) || occursin("What is 5 + 3?", description)
                
                # Test grading with correct answers
                result = mod.grade(workdir, "<answer>8</answer>", "math1")
                @test result isa Dict || result isa Number
                score = result isa Dict ? get(result, "score", result) : result
                @test score == 1.0 || score == 100.0  # Could be 1.0 or 100.0 depending on implementation

                result = mod.grade(workdir, "<answer>6</answer>", "math2")
                score = result isa Dict ? get(result, "score", result) : result
                @test score == 1.0 || score == 100.0

                # Test grading with incorrect answer
                result = mod.grade(workdir, "<answer>7</answer>", "math1")
                score = result isa Dict ? get(result, "score", result) : result
                @test score == 0.0
            end
        end
        
        @testset "Integration with LLMBenchServer" begin
            mktempdir() do workdir
                # Create server using the module's functions
                setup_wrapper = (wd, pid="") -> Main.SimpleBenchModule.setup_problem(wd, pid)
                grade_wrapper = (wd, t, pid="") -> Main.SimpleBenchModule.grade(wd, t, pid)
                
                server = LLMBenchMCPServer.LLMBenchServer(
                    name="SimpleBenchModule",
                    setup_fn=setup_wrapper,
                    grade_fn=grade_wrapper,
                    working_dir=workdir
                )
                
                # Test setup through MCP
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 1,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "setup_problem",
                        "arguments" => Dict()
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                # When no problem_id is provided, should get some response
                @test haskey(response, "result")
                @test haskey(response["result"], "content")
                response_text = response["result"]["content"][1]["text"]
                @test !isempty(response_text)
                
                # Test grading through MCP for math1
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict(
                            "transcript" => "<answer>8</answer>",
                            "problem_id" => "math1"
                        )
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_text = response["result"]["content"][1]["text"]

                # Try to parse as JSON if possible
                grade_result = try
                    JSON.parse(grade_text)
                catch
                    # If not JSON, check if it's a number
                    Dict("score" => tryparse(Float64, grade_text))
                end

                # Should have graded math1 correctly
                if grade_result isa Dict
                    score = get(grade_result, "score", 0.0)
                    @test score == 1.0 || score == 100.0
                end
                
                # Test grading through MCP for math2
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict(
                            "transcript" => "<answer>5</answer>",  # Wrong answer
                            "problem_id" => "math2"
                        )
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_text = response["result"]["content"][1]["text"]

                # Try to parse as JSON if possible
                grade_result = try
                    JSON.parse(grade_text)
                catch
                    # If not JSON, check if it's a number
                    Dict("score" => tryparse(Float64, grade_text))
                end

                # Should have graded math2 incorrectly (5 is wrong, correct is 6)
                if grade_result isa Dict
                    score = get(grade_result, "score", -1.0)
                    @test score == 0.0  # Incorrect answer should score 0
                end
            end
        end
end