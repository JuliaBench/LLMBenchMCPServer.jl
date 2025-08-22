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
        
        # Push testset to capture test results (Test module won't print when inside a testset)
        Test.push_testset(ts)
        try
            # Call the grade function with all arguments
            # Use invokelatest to handle world age issues when loading modules dynamically
            # Always pass all three parameters - the function has a default value for problem_id
            result = Base.invokelatest(tool.grade_fn, tool.working_dir, transcript, problem_id)
        finally
            Test.pop_testset()
        end
        
        # Capture the testset output using redirect_stdout
        # Create a Pipe for capturing stdout
        old_stdout = stdout
        rd, wr = redirect_stdout()
        
        try
            Test.finish(ts)
        catch e
            # finish throws an error if tests fail, but we still want the output
        end
        
        # Restore stdout and close the write end
        redirect_stdout(old_stdout)
        close(wr)
        
        # Read the captured output
        test_output_str = read(rd, String)
        close(rd)
        
        # Check if any tests failed (including in nested testsets)
        function has_failures(testset)
            for r in testset.results
                if isa(r, Test.Fail) || isa(r, Test.Error)
                    return true
                elseif isa(r, DefaultTestSet)
                    if has_failures(r)
                        return true
                    end
                end
            end
            return false
        end
        
        has_test_failures = has_failures(ts)
        
        # Print test errors to stdout so they appear in the UI
        if has_test_failures
            Test.print_test_errors(ts)
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
            
            # Override score to 0 if any tests failed
            if has_test_failures
                result["score"] = 0.0
                # Also set all subscores to 0
                for key in keys(result["subscores"])
                    result["subscores"][key] = 0.0
                end
            end
            
            # Add test output to the grading result
            result["test_output"] = test_output_str
            
            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => JSON.json(result)
                )],
                "isError" => false
            )
            
        elseif isa(result, Number)
            # Simple numeric score
            # Override to 0 if any tests failed
            final_score = has_test_failures ? 0.0 : Float64(result)
            grading_result = Dict(
                "subscores" => Dict("total" => final_score),
                "weights" => Dict("total" => 1.0),
                "score" => final_score,
                "test_output" => test_output_str
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
            # Score is always 0 for non-numeric results or if tests failed
            grading_result = Dict(
                "subscores" => Dict("completion" => 0.0),
                "weights" => Dict("completion" => 1.0),
                "score" => 0.0,
                "details" => string(result),
                "test_output" => test_output_str
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
        
        # Return a failed grade with error
        grading_result = Dict(
            "subscores" => Dict("completion" => 0.0),
            "weights" => Dict("completion" => 1.0),
            "score" => 0.0,
            "error" => error_msg,
            "test_output" => "Test execution failed: grading function threw an exception"
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