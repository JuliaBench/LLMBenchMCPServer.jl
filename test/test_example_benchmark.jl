@testset "Example Benchmark Module" begin
    # Create a test module to simulate a benchmark
    
    # First, create the module file
    mktempdir() do tmpdir
        module_file = joinpath(tmpdir, "ExampleBenchmark.jl")
        
        write(module_file, """
        module ExampleBenchmark
        
        export setup_problem, grade
        
        function setup_problem(workdir::String, problem_id::String="")
            # Create a problem file
            problem_file = joinpath(workdir, "problem.txt")
            write(problem_file, "What is 3 + 5?")
            
            return \"\"\"
            # Math Problem
            
            Solve the following problem:
            What is 3 + 5?
            
            Write your answer to 'answer.txt' in the working directory.
            \"\"\"
        end
        
        function grade(workdir::String, transcript::String, problem_id::String="")
            answer_file = joinpath(workdir, "answer.txt")
            
            if !isfile(answer_file)
                return Dict(
                    "subscores" => Dict("completion" => 0.0),
                    "weights" => Dict("completion" => 1.0),
                    "score" => 0.0,
                    "details" => "No answer file found"
                )
            end
            
            answer = strip(read(answer_file, String))
            
            if answer == "8"
                return Dict(
                    "subscores" => Dict("correctness" => 1.0),
                    "weights" => Dict("correctness" => 1.0),
                    "score" => 1.0,
                    "details" => "Correct answer!"
                )
            else
                return Dict(
                    "subscores" => Dict("correctness" => 0.0),
                    "weights" => Dict("correctness" => 1.0),
                    "score" => 0.0,
                    "details" => "Incorrect answer: got '\$answer', expected '8'"
                )
            end
        end
        
        end # module
        """)
        
        # Load the module
        include(module_file)
        
        @testset "Module functions" begin
            # Get the module
            mod = Main.ExampleBenchmark
            
            mktempdir() do workdir
                # Test setup_problem (use invokelatest for dynamically loaded module)
                description = Base.invokelatest(mod.setup_problem, workdir)
                @test occursin("3 + 5", description)
                @test isfile(joinpath(workdir, "problem.txt"))
                
                # Test grade with correct answer
                write(joinpath(workdir, "answer.txt"), "8")
                result = Base.invokelatest(mod.grade, workdir, "I calculated 3 + 5 = 8")
                @test result["score"] == 1.0
                @test result["details"] == "Correct answer!"
                
                # Test grade with incorrect answer
                write(joinpath(workdir, "answer.txt"), "7")
                result = Base.invokelatest(mod.grade, workdir, "I think it's 7")
                @test result["score"] == 0.0
                @test occursin("Incorrect", result["details"])
                
                # Test grade with no answer
                rm(joinpath(workdir, "answer.txt"))
                result = Base.invokelatest(mod.grade, workdir, "I didn't write an answer")
                @test result["score"] == 0.0
                @test occursin("No answer file", result["details"])
            end
        end
        
        @testset "Integration with LLMBenchServer" begin
            mktempdir() do workdir
                # Create server using the module's functions (wrapped for world age)
                setup_wrapper = (wd, pid="") -> Base.invokelatest(Main.ExampleBenchmark.setup_problem, wd, pid)
                grade_wrapper = (wd, t, pid="") -> Base.invokelatest(Main.ExampleBenchmark.grade, wd, t, pid)
                
                server = LLMBenchMCPServer.LLMBenchServer(
                    name="ExampleBenchmark",
                    setup_fn=setup_wrapper,
                    grade_fn=grade_wrapper,
                    working_dir=workdir
                )
                
                # Test setup
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
                @test occursin("3 + 5", response["result"]["content"][1]["text"])
                
                # Simulate solving the problem using bash tool
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 2,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "bash",
                        "arguments" => Dict("command" => "echo '8' > answer.txt")
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                @test haskey(response, "result")
                
                # Test grading
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => 3,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "grade_problem",
                        "arguments" => Dict("transcript" => "I wrote 8 to answer.txt")
                    )
                )
                
                response = ClaudeMCPTools.handle_request(server, request)
                grade_result = JSON.parse(response["result"]["content"][1]["text"])
                @test grade_result["score"] == 1.0
                @test grade_result["details"] == "Correct answer!"
            end
        end
    end
end