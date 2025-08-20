"""
Grade Problem Tool for LLM Benchmark
"""

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
    problem_id = get(params, "problem_id", "default")
    transcript = get(params, "transcript", "")
    
    try
        # Call the grade function with working directory and transcript
        result = tool.grade_fn(tool.working_dir, transcript)
        
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
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => JSON.json(result)
            )])
            
        elseif isa(result, Number)
            # Simple numeric score
            grading_result = Dict(
                "subscores" => Dict("total" => Float64(result)),
                "weights" => Dict("total" => 1.0),
                "score" => Float64(result)
            )
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => JSON.json(grading_result)
            )])
            
        else
            # Convert to string and return as details
            grading_result = Dict(
                "subscores" => Dict("completion" => 0.0),
                "weights" => Dict("completion" => 1.0),
                "score" => 0.0,
                "details" => string(result)
            )
            
            return Dict("content" => [Dict(
                "type" => "text",
                "text" => JSON.json(grading_result)
            )])
        end
        
    catch e
        error_msg = "Failed to grade problem: " * string(e)
        
        # Return a failed grade with error
        grading_result = Dict(
            "subscores" => Dict("completion" => 0.0),
            "weights" => Dict("completion" => 1.0),
            "score" => 0.0,
            "error" => error_msg
        )
        
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => JSON.json(grading_result)
        )])
    end
end