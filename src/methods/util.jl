# Utility #
# ========================== #
function eval_objective(objective::JuMP.GenericQuadExpr,x::AbstractVector)
    aff = objective.aff
    val = aff.constant
    for (i,var) in enumerate(aff.vars)
        val += aff.coeffs[i]*x[var.col]
    end
    return val
end

function fill_solution!(stochasticprogram::JuMP.Model)
    dep = DEP(stochasticprogram)
    # First stage
    nrows, ncols = length(stochasticprogram.linconstr), stochasticprogram.numCols
    stochasticprogram.objVal = dep.objVal
    stochasticprogram.colVal = dep.colVal[1:ncols]
    stochasticprogram.redCosts = dep.redCosts[1:ncols]
    stochasticprogram.linconstrDuals = dep.linconstrDuals[1:nrows]
    # Second stages
    fill_solution!(scenarioproblems(stochasticprogram), dep.colVal[ncols+1:end], dep.redCosts[ncols+1:end], dep.linconstrDuals[nrows+1:end])
    nothing
end
function fill_solution!(scenarioproblems::ScenarioProblems{D,SD,S}, x::AbstractVector, μ::AbstractVector, λ::AbstractVector) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    cbegin = 0
    rbegin = 0
    for (i,subproblem) in enumerate(subproblems(scenarioproblems))
        snrows, sncols = length(subproblem.linconstr), subproblem.numCols
        subproblem.colVal = x[cbegin+1:cbegin+sncols]
        subproblem.redCosts = μ[cbegin+1:cbegin+sncols]
        subproblem.linconstrDuals = λ[rbegin+1:rbegin+snrows]
        subproblem.objVal = eval_objective(subproblem.obj,subproblem.colVal)
        cbegin += sncols
        rbegin += snrows
    end
end
function fill_solution!(scenarioproblems::DScenarioProblems{D,SD,S}, x::AbstractVector, μ::AbstractVector, λ::AbstractVector) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    cbegin = 0
    rbegin = 0
    active_workers = Vector{Future}(length(scenarioproblems))
    for p in 1:length(scenarioproblems)
        wncols = remotecall_fetch((sp)->sum([s.numCols::Int for s in fetch(sp).problems]),p+1,scenarioproblems[p])
        wnrows = remotecall_fetch((sp)->sum([length(s.linconstr)::Int for s in fetch(sp).problems]),p+1,scenarioproblems[p])
        active_workers[p] = remotecall((sp,x,μ,λ)->fill_solution!(fetch(sp),x,μ,λ),
                                       p+1,
                                       scenarioproblems[p],
                                       x[cbegin+1:cbegin+wncols],
                                       μ[cbegin+1:cbegin+wncols],
                                       λ[rbegin+1:rbegin+wnrows]
                                       )
        cbegin += wncols
        rbegin += wnrows
    end
    @async map(wait,active_workers)
end

function calculate_objective_value(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    objective_value = eval_objective(stochasticprogram.obj,stochasticprogram.colVal)
    objective_value += calculate_subobjectives(scenarioproblems(stochasticprogram))
    return objective_value
end
function calculate_subobjectives(scenarioproblems::ScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return sum([(probability(scenario)*eval_objective(subprob.obj,subprob.colVal))::Float64 for (scenario,subprob) in zip(scenarios(scenarioproblems),subproblems(scenarioproblems))])
end
function calculate_subobjectives(scenarioproblems::DScenarioProblems{D,SD,S}) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    return sum([remotecall_fetch((sp) -> calculate_subobjectives(fetch(sp)),
                                 p+1,
                                 scenarioproblems[p]) for p in 1:length(scenarioproblems)])
end

function invalidate_cache!(stochasticprogram::JuMP.Model)
    haskey(stochasticprogram.ext,:SP) || error("The given model is not a stochastic program.")
    cache = problemcache(stochasticprogram)
    delete!(cache,:evp)
    delete!(cache,:dep)
end

function masterterms(scenarioproblems::ScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    model = scenarioproblems.problems[i]
    parent = parentmodel(scenarioproblems)
    return [begin
              if var.m == parent
                (i,var.col,-constr.terms.coeffs[j])
              end
            end for (i,constr) in enumerate(model.linconstr) for (j,var) in enumerate(constr.terms.vars)]
end

function masterterms(scenarioproblems::DScenarioProblems{D,SD,S},i::Integer) where {D, SD <: AbstractScenarioData, S <: AbstractSampler{SD}}
    j = 0
    for p in 1:length(scenarioproblems)
        n = remotecall_fetch((sp)->length(fetch(sp).scenariodata),p+1,scenarioproblems[p])
        if i <= n+j
            return remotecall_fetch((sp,idx) -> begin
                                      scenarioproblems = fetch(sp)
                                      model = scenarioproblems.problems[idx]
                                      parent = parentmodel(scenarioproblems)
                                      return [(i,var.col,-constr.terms.coeffs[j]) for (i,constr) in enumerate(model.linconstr) for (j,var) in enumerate(constr.terms.vars) if var.m == parent]
                                    end,
                                    p+1,
                                    scenarioproblems[p],
                                    i-j)
        end
        j += n
    end
    throw(BoundsError(scenarioproblems,i))
end

function transfer_model!(dest::StochasticProgramData,src::StochasticProgramData)
    empty!(dest.generator)
    copy!(dest.generator,src.generator)
    return dest
end

function transfer_scenarios!(dest::StochasticProgramData,src::StochasticProgramData)
    append!(dest,scenarios(src))
    return dest
end

function pick_solver(stochasticprogram,supplied_solver)
    current_solver = stochasticprogram.ext[:SP].spsolver.solver
    solver = if current_solver isa JuMP.UnsetSolver
        supplied_solver
    else
        current_solver
    end
    return solver
end

optimsolver(solver::MathProgBase.AbstractMathProgSolver) = solver
# ========================== #