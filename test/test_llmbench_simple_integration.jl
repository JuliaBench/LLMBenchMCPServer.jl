# Create a test module directly
module SimpleBenchModule
    # Simple test implementation that mimics LLMBenchSimple behavior
    const BENCHMARKS = Dict{String, Any}()

    function __init__()
        # Clear any existing benchmarks
        empty!(BENCHMARKS)

        # Add test benchmarks
        BENCHMARKS["math1"] = Dict("prompt" => "What is 5 + 3?", "answer" => 8)
        BENCHMARKS["math2"] = Dict("prompt" => "What is 10 - 4?", "answer" => 6)
    end

    # Simple setup function
    function setup_problem(workdir::String, problem_id::String="")
        if isempty(problem_id)
            # Return error with available problems
            available = join(keys(BENCHMARKS), ", ")
            return "Error: problem_id is required. Available problems: $available"
        end

        if !haskey(BENCHMARKS, problem_id)
            return "Error: Unknown problem_id: $problem_id"
        end

        return BENCHMARKS[problem_id]["prompt"]
    end

    # Simple grade function
    function grade(workdir::String, transcript::String, problem_id::String="")
        result = Dict{String, Any}("subscores" => Dict{String, Any}())

        if isempty(problem_id)
            # Return error result
            result["score"] = 0.0
            result["details"] = "Error: problem_id is required"
            return result
        end

        if !haskey(BENCHMARKS, problem_id)
            result["score"] = 0.0
            result["details"] = "Unknown problem_id: $problem_id"
            return result
        end

        # Extract answer from transcript
        answer_match = match(r"<answer>(\d+)</answer>", transcript)
        if isnothing(answer_match)
            result["subscores"][problem_id] = 0.0
            result["score"] = 0.0
            result["details"] = "No answer found"
            return result
        end

        answer = parse(Int, answer_match.captures[1])
        correct_answer = BENCHMARKS[problem_id]["answer"]

        is_correct = answer == correct_answer
        result["subscores"][problem_id] = is_correct ? 1.0 : 0.0
        result["score"] = is_correct ? 1.0 : 0.0
        result["details"] = is_correct ? "Correct" : "Incorrect (expected $correct_answer, got $answer)"

        return result
    end
end # module

using LLMBenchMCPServer
using ClaudeMCPTools
using JSON

@testset "LLMBenchSimple Integration" begin
    @testset "Module with LLMBenchSimple functions" begin
        # Get the module
        mod = Main.SimpleBenchModule
        
        # Initialize the module to set up benchmarks
        Base.invokelatest(mod.__init__)
        
        mktempdir() do workdir
                # Test setup_problem with empty problem_id (should return error)
                description = Base.invokelatest(mod.setup_problem, workdir, "")
                @test occursin("problem_id is required", description)
                @test occursin("math1", description)
                @test occursin("math2", description)

                # Test setup_problem for specific problem
                description = Base.invokelatest(mod.setup_problem, workdir, "math1")
                @test description == "What is 5 + 3?"
                
                # Test grading with correct answers
                result = Base.invokelatest(mod.grade, workdir, "<answer>8</answer>", "math1")
                if result["score"] != 1.0
                    @info "Grade result for math1 with answer 8" result
                end
                @test result["score"] == 1.0
                
                result = Base.invokelatest(mod.grade, workdir, "<answer>6</answer>", "math2")
                if result["score"] != 1.0
                    @info "Grade result for math2 with answer 6" result
                end
                @test result["score"] == 1.0
                
                # Test grading with incorrect answer
                result = Base.invokelatest(mod.grade, workdir, "<answer>7</answer>", "math1")
                @test result["score"] == 0.0
                
                # Test grading with empty problem_id (should return error)
                result = Base.invokelatest(mod.grade, workdir, "<answer>8</answer>", "")
                @test result["score"] == 0.0
                @test occursin("problem_id is required", result["details"])
            end
        end
        
        @testset "Integration with LLMBenchServer" begin
            # Initialize the module
            Base.invokelatest(Main.SimpleBenchModule.__init__)
            
            mktempdir() do workdir
                # Create server using the module's functions (wrapped for world age)
                setup_wrapper = (wd, pid="") -> Base.invokelatest(Main.SimpleBenchModule.setup_problem, wd, pid)
                grade_wrapper = (wd, t, pid="") -> Base.invokelatest(Main.SimpleBenchModule.grade, wd, t, pid)
                
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
                # When no problem_id is provided, it should return an error message listing available problems
                @test occursin("problem_id is required", response["result"]["content"][1]["text"])
                @test occursin("math1", response["result"]["content"][1]["text"])
                @test occursin("math2", response["result"]["content"][1]["text"])
                
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
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                
                # Should have graded math1 correctly
                @test haskey(grade_result, "subscores")
                @test grade_result["subscores"]["math1"] == 1.0  # Correct
                @test grade_result["score"] == 1.0
                
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
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                
                # Should have graded math2 incorrectly
                @test haskey(grade_result, "subscores")
                @test grade_result["subscores"]["math2"] == 0.0  # Incorrect
                @test grade_result["score"] == 0.0
            end
        end
end