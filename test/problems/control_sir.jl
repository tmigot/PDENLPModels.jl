using Plots, LinearAlgebra, SparseArrays
###############################################################
#Data for SIS
x0 = [1, 2] #I, S, R
N = sum(x0)

a = 0.2
b = 0.1 #0.1 ou 0.7
μ = 0.1 #vaccination rate :)
#=
# The usual SIR:
F(x) = vcat(a .* x[1:n] .* x[n+1:2*n] .- b .* x[1:n], 
            -c .- a .* x[1:n] .* x[n+1:2*n],
            b .* x[2 * n + 1: 3 * n] .+ c
            )
=#
#The simple SIR: Kermack and Mckendrick
# A note on Exact solution of SIR and SIS epidemic models, Shabbir-Khan-Sadiq
F(x) = vcat(a .* x[1:n] .* x[n+1:2*n] .- b .* x[1:n], 
            μ .- a .* x[1:n] .* x[n+1:2*n] .- b .* x[1:n]
            ) #R is others
T = 1 #final time
###############################################################
#Now we discretize by hand with forward finite differences
n = 10
h = T/n

AI = 1/h * Bidiagonal(ones(n), -ones(n-1), :L)
AS = 1/h * Bidiagonal(ones(n), -ones(n-1), :L)
A0 = zeros(2 * n); A0[1] = -x0[1] / h; A0[n+1] = -x0[2] / h;

c(x) = vcat(AI * x[1:n], AS * x[n+1:2*n]) + A0 - F(x)

################################################################
# The exact solution of the ODE is given by:
#=
#known in implicit form in: 
Exact analytical solutions of the Susceptible-Infected-Recovered (SIR) epidemic
model and of the SIR model with equal death and birth rates, Harko-Lobo-Mak
Applied Mathematics and Computation, 2014
function solI(t)
    ρ = a * N - b + a * x0[1] * (exp((a * N - b) * t) - 1)
    I = (a * N - b) * x0[1] * exp((a * N - b) * t) / ρ
    S = N - I
    return I
end

function solS(t)
  ρ = a * N - b + a * x0[1] * (exp((a * N - b) * t) - 1)
  I = (a * N - b) * x0[1] * exp((a * N - b) * t) / ρ
  S = N - I
  return S
end
=#
C = x0[1] + x0[2] - 1
λ = a - b + a * C
function solI(t) #If μ == b
    ρ = a + λ * ( λ - x0[1]*a ) / ( λ * x0[1] * exp(a * C /b ) ) * exp(-λ * t + a  * C / b)
    I = λ / ρ
    S = 1 + C * (1 - b * t) - I
    return I
end

function solS(t)
    ρ = a + λ * ( λ - x0[1]*a ) / ( λ * x0[1] * exp(a * C /b ) ) * exp(-λ * t + a  * C / b)
    I = λ / ρ
    S = 1 + C * (1 - b * t) - I
  return S
end
################################################################
# Some checks and plots
# Vectorized solution
sol_Ih = [solI(t) for t=h:h:T]
sol_Sh = [solS(t) for t=h:h:T]

@show norm(c(vcat(sol_Ih, sol_Sh)), Inf) #check the discretization by hand

plot(0:h:T, vcat(x0[1], sol_Ih))
plot!(0:h:T, vcat(x0[2], sol_Sh))

png("test")

################################################################
# Using Gridap and PDENLPModels
using Gridap, PDENLPModels

function sis_gridap(x0, n, a, b, T)
    model = CartesianDiscreteModel((0,T),n)

    labels = get_face_labeling(model)
    add_tag_from_tags!(labels,"diri0",[1]) #initial time condition

    #=
    V = TestFESpace(
        reffe=:Lagrangian, conformity=:H1, valuetype=VectorValue{2,Float64},
        model=model, labels=labels, order=1, dirichlet_tags=["diri0"])
    uD0 = VectorValue(x0[1], x0[2])  
    U = TrialFESpace(V,uD0)
    =#

    VI = TestFESpace(
        reffe=:Lagrangian, conformity=:H1, valuetype=Float64,
        model=model, labels=labels, order=1, dirichlet_tags=["diri0"]) 
    UI = TrialFESpace(VI, x0[1])
    VS = TestFESpace(
        reffe=:Lagrangian, conformity=:H1, valuetype=Float64,
        model=model, labels=labels, order=1, dirichlet_tags=["diri0"])
    US = TrialFESpace(VS, x0[2])
    X = MultiFieldFESpace([VI, VS])
    Y = MultiFieldFESpace([UI, US])

    @law conv(u,∇u) = (∇u ⋅one(∇u))⊙u
    c(u,v) = conv(v,∇(u)) #v⊙conv(u,∇(u))
    _a(x) = a 
    _b(x) = b 
    _μ(x) = μ
    function res_pde(u,v)
        I, S = u
        p, q = v
        c(I, p) + c(S, q) - p * ( _a * S * I - _b * I ) - q * (_μ -_b * I - _a * S * I)
    end

    trian = Triangulation(model)
    degree = 1
    quad = CellQuadrature(trian,degree)
    t_Ω = FETerm(res_pde,trian,quad)
    op_sis = FEOperator(Y,X,t_Ω)

    function f(u) #:: Union{Gridap.MultiField.MultiFieldFEFunction, Gridap.CellData.GenericCellField}
        I, S = u
        0.5 * I * I
    end

    ndofs = Gridap.FESpaces.num_free_dofs(Y)
    xin   = zeros(ndofs)
    nlp = GridapPDENLPModel(xin, f, trian, quad, Y, X, op_sis) 
    return nlp
end

################################################################
# Testing:
using NLPModelsTest, Test

atol, rtol = √eps(), √eps()
# check the value at the solution:
kmax = 6 #beyond is tough
for k=1:kmax
    local sol_Ih, sol_Sh, h, n, nlp
    n = 10^k
    nlp = sis_gridap(x0, n, a, b, T)
    h = T/n
    sol_Ih = [solI(t) for t=h:h:T]
    sol_Sh = [solS(t) for t=h:h:T]
    res = norm(cons(nlp, vcat(sol_Ih, sol_Sh)), Inf)
    @show res
    if res <= 1e-7
        @test true
        break
    end
    if k == kmax @test false end
end
n = 10
nlp = sis_gridap(x0, n, a, b, T)
xr = rand(nlp.meta.nvar)
#there are no objective function here
@test obj(nlp, nlp.meta.x0) == x0[1]^2/8/n #:-)
#@test obj(nlp, xr) - 1/n * (x0[1]^2/4 + 0.5 * sum([xr[i]^2 for i=1:n-1]) + xr[n]^2/4)

#check derivatives
@test gradient_check(nlp, x = xr, atol = atol, rtol = rtol) == Dict{Tuple{Int64,Int64},Float64}()
@test jacobian_check(nlp, x = xr, atol = atol, rtol = rtol) == Dict{Tuple{Int64,Int64},Float64}()
ymp = hessian_check(nlp, x = xr, atol = atol, rtol = rtol)
@test !any(x -> x!=Dict{Tuple{Int64,Int64},Float64}(), values(ymp))
ymp2 = hessian_check_from_grad(nlp, x = xr, atol = atol, rtol = rtol)
@test !any(x -> x!=Dict{Tuple{Int64,Int64},Float64}(), values(ymp2))