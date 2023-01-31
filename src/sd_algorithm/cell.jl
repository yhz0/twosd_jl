"""
Master problem and intermediate solver information.
"""
mutable struct sdCell
    # Master Problem
    master::Model

    # Reference to first stage variables, constraints, epigrpah in master problem
    x_ref::Vector{VariableRef}
    root_stage_con::Vector{ConstraintRef}

    # Objective function expression in the master, incl epigraph terms,
    # but without the prox terms
    objf::QuadExpr

    # Epigraph information
    epi::Vector{sdEpigraph}

    # Epigraph variables and constraints in the master
    epivar_ref::Vector{VariableRef}
    epicon_ref::Vector{Vector{ConstraintRef}}

    # Regularization strength; might not be used
    reg::Float64

    # Dual vertices found so far (Warning: concurrent issues)
    dual_vertices::Set{Vector{Float64}}

    # Candidate and incumbent solutions found so far
    x_candidate::Vector{Float64}
    x_incumbent::Vector{Float64}
end

"""
Copy master problem and master constraints into the cell.
"""
function sdCell(root_prob::spStageProblem)
    # Initialize master problem by copying
    new_root_prob::spStageProblem = copy(root_prob)
    master = new_root_prob.model
    x_ref = new_root_prob.current_stage_vars
    root_stage_con = new_root_prob.stage_constraints
    objf = objective_function(master)

    epivar_ref = []
    epicon_ref = []
    epi = []
    reg = 0.0

    xlen = length(x_ref)
    return sdCell(master, x_ref, root_stage_con, objf,
        epi, epivar_ref, epicon_ref,
        reg, Set{Vector{Float64}}(), zeros(xlen), zeros(xlen))
end

"""
Pretty print sdCell structure.
"""
function Base.show(io::IO, cell::sdCell)
    println(io, "sdCell")
    master_con_cnt = num_constraints(cell.master;
        count_variable_in_set_constraints = false)
    master_var_cnt = num_variables(cell.master)
    println(io, "Master con_cnt=$master_con_cnt var_cnt=$master_var_cnt")
    epi_cnt = length(cell.epi)
    println(io, "Epigraph cnt=$epi_cnt")
    for epi in cell.epi
        println(io, epi)
    end
    return
end

"""
Add epigraph variable to cell. Will update the objective function.
"""
function bind_epigraph!(cell::sdCell, epi::sdEpigraph)
    push!(cell.epi, epi)

    epiv = @variable(cell.master)
    set_lower_bound(epiv, epi.lower_bound)

    push!(cell.epivar_ref, epiv)
    push!(cell.epicon_ref, [])

    add_to_expression!(cell.objf, epi.objective_weight, epiv)
    set_objective_function(cell.master, cell.objf)
    return
end

"""
Reset the cell objective to the one without regularization term,
keeping the epigraph variable settings.
"""
function reset_objective!(cell::sdCell)
    set_objective_function(cell.master, cell.objf)
    return
end

"""
Add regularization with respect to a point x0. Will reset the objective first.
"""
function add_regularization!(cell::sdCell, x0::Vector{Float64}, rho::Float64)
    reg_terms = sum(rho/2 * (cell.x_ref[i] - x0[i])^2 for i in eachindex(x0))
    set_objective_function(cell.master, cell.objf + reg_terms)
    return
end

"""
Remove cuts associated with the specified epigraph in the cell structure.
"""
function remove_cuts!(cell::sdCell, epi_num::Int)
    for con in cell.epicon_ref[epi_num]
        delete(cell.master, con)
    end
    empty!(cell.epicon_ref[epi_num])
    return
end

"""
Remove all epigraph cuts recorded in the cell structure.
"""
function remove_cuts!(cell::sdCell)
    # Remove the constraints
    for i in eachindex(cell.epicon_ref)
        remove_cuts!(cell, i)
    end
    return
end

"""
Remove the epigraph cuts and then add the cuts associated with it.
Added constraints are recorded in the cell structure.
This will not add any cut if the total epigraph scenario weight is 0.
"""
function sync_cuts!(cell::sdCell, epi::sdEpigraph, epi_num::Int)
    if epi.total_scenario_weight == 0.0
        return
    end

    remove_cuts!(cell, epi_num)
    
    epi_ref = cell.epivar_ref[epi_num]
    x_ref = cell.epivar_ref

    for cut in epi.cuts
        # Normal cuts are discounted
        discount = cut.weight_mark / epi.total_scenario_weight
        con = add_cut_to_master!(cell.master, cut, epi_ref, x_ref,
            discount, epi.lower_bound)

        push!(cell.epicon_ref[epi_num], con)
    end

    # Add the incumbent if exists
    if epi.incumbent_cut !== nothing
        discount = 1.0
        con = add_cut_to_master!(cell.master, epi.incumbent_cut, epi_ref, x_ref,
            discount, epi.lower_bound)
        push!(cell.epicon_ref[epi_num], con)
    end

    return
end

"""
Remove the cuts then add all epigragh cuts to a cell, including the incumbent
if exists.
"""
function sync_cuts!(cell::sdCell)
    for (i, epi) in enumerate(cell.epi)
        sync_epigraph_cuts!(cell, epi, i)
    end
end
