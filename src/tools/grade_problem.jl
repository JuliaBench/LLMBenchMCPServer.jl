"""
Grade Problem Tool for LLM Benchmark
"""

import Test: DefaultTestSet, finish

mutable struct GradeProblemTool <: ClaudeMCPTools.MCPTool
    grade_fn::Function
    working_dir::String
    
    function GradeProblemTool(grade_fn::Function; working_dir::String=pwd())
        new(grade_fn, working_dir)
    end
end

function ClaudeMCPTools.tool_schema(::GradeProblemTool)
    return Dict(
        "name" => "grade_problem",
        "description" => "Grade the solution and return scores",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "problem_id" => Dict(
                    "type" => "string",
                    "description" => "The problem identifier (optional)"
                ),
                "transcript" => Dict(
                    "type" => "string",
                    "description" => "The transcript of the solution process"
                )
            ),
            "required" => ["transcript"]
        )
    )
end

function ClaudeMCPTools.execute(tool::GradeProblemTool, params::Dict)
    problem_id = get(params, "problem_id", "")
    transcript = get(params, "transcript", "")
    
    try
        # Create a custom testset for grading
        testset_name = isempty(problem_id) ? "grading" : "grading: $problem_id"
        ts = DefaultTestSet(testset_name; verbose=false)
        
        # Variable to store the grading result
        result = nothing
        
        # Capture output using devnull to suppress test output
        Test.push_testset(ts)
        redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                # Call the grade function with all arguments
                # Use invokelatest to handle world age issues when loading modules dynamically
                # Always pass all three parameters - the function has a default value for problem_id
                result = Base.invokelatest(tool.grade_fn, tool.working_dir, transcript, problem_id)
            end
        end
        Test.pop_testset()
        
        # Format testset results
        test_summary = Dict{String,Any}(
            "description" => ts.description,
            "passed" => ts.n_passed,
            "failed" => count(r -> isa(r, Test.Fail), ts.results),
            "errored" => count(r -> isa(r, Test.Error), ts.results),
            "broken" => count(r -> isa(r, Test.Broken), ts.results),
            "total" => ts.n_passed + length(ts.results)
        )
        
        # Collect details about failures
        failures = []
        for r in ts.results
            if isa(r, Test.Fail)
                push!(failures, Dict(
                    "type" => "fail",
                    "expression" => string(r.orig_expr),
                    "message" => r.data !== nothing ? string(r.data) : ""
                ))
            elseif isa(r, Test.Error)
                push!(failures, Dict(
                    "type" => "error",
                    "expression" => string(r.orig_expr),
                    "message" => string(r.value)
                ))
            elseif isa(r, DefaultTestSet)
                # Nested testset
                nested_summary = Dict(
                    "description" => r.description,
                    "passed" => r.n_passed,
                    "failed" => count(x -> isa(x, Test.Fail), r.results),
                    "errored" => count(x -> isa(x, Test.Error), r.results)
                )
                push!(test_summary, "nested" => nested_summary)
            end
        end
        
        if !isempty(failures)
            test_summary["failures"] = failures
        end
        
        # Debug: Print the result type
        @debug "Grade function returned: $(typeof(result))"
        
        # The grade function should return a grading result
        # It could be a Dict with subscores, weights, and total score
        if isa(result, Dict)
            # Convert to Dict{String,Any} if needed to allow mixed types
            if !(result isa Dict{String,Any})
                result = Dict{String,Any}(k => v for (k,v) in result)
            end
            
            # Ensure it has the expected structure
            if !haskey(result, "subscores")
                result["subscores"] = Dict("completion" => 0.0)
            end
            if !haskey(result, "weights")
                result["weights"] = Dict("completion" => 1.0)
            end
            if !haskey(result, "score")
                # Calculate total score if not provided
                subscores = result["subscores"]
                weights = result["weights"]
                total = 0.0
                
                # Calculate weighted sum
                for (k, weight) in weights
                    score = get(subscores, k, 0.0)
                    total += score * weight
                end
                
                result["score"] = total
            end
            
            # Add test results to the grading result
            result["test_results"] = test_summary
            
            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => JSON.json(result)
                )],
                "isError" => false
            )
            
        elseif isa(result, Number)
            # Simple numeric score
            grading_result = Dict(
                "subscores" => Dict("total" => Float64(result)),
                "weights" => Dict("total" => 1.0),
                "score" => Float64(result),
                "test_results" => test_summary
            )
            
            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => JSON.json(grading_result)
                )],
                "isError" => false
            )
            
        else
            # Convert to string and return as details
            grading_result = Dict(
                "subscores" => Dict("completion" => 0.0),
                "weights" => Dict("completion" => 1.0),
                "score" => 0.0,
                "details" => string(result),
                "test_results" => test_summary
            )
            
            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => JSON.json(grading_result)
                )],
                "isError" => false
            )
        end
        
    catch e
        # Get a proper error message with backtrace
        io = IOBuffer()
        showerror(io, e, catch_backtrace())
        error_msg = "Failed to grade problem:\n" * String(take!(io))
        
        # Also print to stderr for debugging
        @error "Grade problem failed" exception=(e, catch_backtrace())
        
        # Create a test summary for the error case
        error_test_summary = Dict{String,Any}(
            "description" => isempty(problem_id) ? "grading" : "grading: $problem_id",
            "passed" => 0,
            "failed" => 0,
            "errored" => 1,
            "broken" => 0,
            "total" => 1,
            "error_message" => error_msg
        )
        
        # Return a failed grade with error
        grading_result = Dict(
            "subscores" => Dict("completion" => 0.0),
            "weights" => Dict("completion" => 1.0),
            "score" => 0.0,
            "error" => error_msg,
            "test_results" => error_test_summary
        )
        
        return Dict(
            "content" => [Dict(
                "type" => "text",
                "text" => JSON.json(grading_result)
            )],
            "isError" => true
        )
    end
end