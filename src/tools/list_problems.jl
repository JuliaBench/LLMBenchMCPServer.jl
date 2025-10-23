"""
    ListProblemsTool

MCP tool to list available benchmark problems.
"""
struct ListProblemsTool <: ClaudeMCPTools.MCPTool
    list_fn::Union{Function, Nothing}
    working_dir::String

    function ListProblemsTool(list_fn::Union{Function, Nothing}=nothing;
                             working_dir::String=pwd())
        new(list_fn, working_dir)
    end
end

function ClaudeMCPTools.tool_schema(tool::ListProblemsTool)
    return Dict(
        "name" => "list_problems",
        "description" => "List all available benchmark problems",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict{String,Any}(),
            "required" => String[]
        )
    )
end

function ClaudeMCPTools.execute(tool::ListProblemsTool, params::AbstractDict)
    # Call the list function
    if tool.list_fn !== nothing
        try
            problems = Base.invokelatest(tool.list_fn)

            # Handle two formats:
            # 1. Vector of Dicts (new format with metadata)
            # 2. Vector of Strings (old format, backward compatible)
            problems_list = if !isempty(problems) && problems[1] isa Dict
                # New format: problems already have metadata
                # Ensure each has at least an id, name, description, category
                [merge(
                    Dict{String,Any}(
                        "name" => get(p, "id", ""),
                        "description" => "",
                        "category" => "general"
                    ),
                    p  # Metadata from @bench overrides defaults
                ) for p in problems]
            else
                # Old format: convert strings to dicts
                [Dict{String,Any}(
                    "id" => string(p),
                    "name" => string(p),
                    "description" => "",
                    "category" => "general"
                ) for p in problems]
            end

            problems_json = Dict("problems" => problems_list)

            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => JSON.json(problems_json)
                )],
                "isError" => false
            )
        catch e
            io = IOBuffer()
            showerror(io, e, catch_backtrace())
            error_msg = "Failed to list problems:\n" * String(take!(io))

            return Dict(
                "content" => [Dict(
                    "type" => "text",
                    "text" => error_msg
                )],
                "isError" => true
            )
        end
    else
        return Dict(
            "content" => [Dict(
                "type" => "text",
                "text" => "No list_problems function configured"
            )],
            "isError" => true
        )
    end
end