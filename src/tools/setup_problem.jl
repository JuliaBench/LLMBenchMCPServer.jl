"""
Setup Problem Tool for LLM Benchmark
"""

mutable struct SetupProblemTool <: ClaudeMCPTools.MCPTool
    setup_fn::Function
    working_dir::String
    
    function SetupProblemTool(setup_fn::Function; working_dir::String=pwd())
        new(setup_fn, working_dir)
    end
end

function ClaudeMCPTools.tool_schema(::SetupProblemTool)
    return Dict(
        "name" => "setup_problem",
        "description" => "Set up the problem environment and return the problem description",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "problem_id" => Dict(
                    "type" => "string",
                    "description" => "The problem identifier (optional)"
                )
            ),
            "required" => String[]
        )
    )
end

function ClaudeMCPTools.execute(tool::SetupProblemTool, params::Dict)
    problem_id = get(params, "problem_id", "default")
    
    try
        # Call the setup function with the working directory
        result = tool.setup_fn(tool.working_dir)
        
        # The setup function should return a problem description
        # Format it as a proper MCP response
        if isa(result, String)
            description = result
        elseif isa(result, Dict)
            # If it returns a dict, try to extract description
            description = get(result, "description", JSON.json(result))
        else
            description = string(result)
        end
        
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => description
        )])
        
    catch e
        error_msg = "Failed to setup problem: " * string(e)
        return Dict("content" => [Dict(
            "type" => "text",
            "text" => error_msg
        )])
    end
end