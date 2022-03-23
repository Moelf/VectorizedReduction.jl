#
# Date created: 2022-03-22
# Author: aradclif
#
#
############################################################################################

# reduction over all dims
function vvlogsumexp(A::AbstractArray{T, N}, ::Colon) where {T, N}
    vmax = typemin(T)
    s = zero(promote_type(T, Float64))
    @turbo for i ∈ eachindex(A)
        vmax = max(A[i], vmax)
    end
    @turbo for i ∈ eachindex(A)
        s += exp(A[i] - vmax)
    end
    vmax + log(s)
end

vvlogsumexp(A) = vvlogsumexp(A, :)

################
# Single allocation version
function vvlogsumexp(A::AbstractArray{T, N}, dims::NTuple{M, Int}) where {T, N, M}
    Dᴬ = size(A)
    Dᴮ′ = ntuple(d -> d ∈ dims ? 1 : Dᴬ[d], Val(N))
    B = similar(A, Base.promote_op(exp, T), Dᴮ′)
    _vvmapreduce!(identity, max, typemin, B, A, dims)
    _vvlogsumexp!(B, A, dims)
    return B
end

function staticdim_logsumexp_quote(static_dims::Vector{Int}, N::Int)
    A = Expr(:ref, :A, ntuple(d -> Symbol(:i_, d), N)...)
    Bᵥ = Expr(:call, :view, :B)
    Bᵥ′ = Expr(:ref, :Bᵥ)
    rinds = Int[]
    nrinds = Int[]
    for d = 1:N
        if d ∈ static_dims
            push!(Bᵥ.args, Expr(:call, :firstindex, :B, d))
            push!(rinds, d)
        else
            push!(Bᵥ.args, :)
            push!(nrinds, d)
            push!(Bᵥ′.args, Symbol(:i_, d))
        end
    end
    reverse!(rinds)
    reverse!(nrinds)
    if !isempty(nrinds)
        block = Expr(:block)
        loops = Expr(:for, :($(Symbol(:i_, nrinds[1])) = indices((A, B), $(nrinds[1]))), block)
        for d ∈ @view(nrinds[2:end])
            newblock = Expr(:block)
            push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = indices((A, B), $d)), newblock))
            block = newblock
        end
        rblock = block
        # Pre-reduction
        vmax = Expr(:(=), :vmax, Bᵥ′)
        push!(rblock.args, vmax)
        ξ = Expr(:(=), :ξ, Expr(:call, :zero, Expr(:call, :eltype, :Bᵥ)))
        push!(rblock.args, ξ)
        # Reduction loop
        for d ∈ rinds
            newblock = Expr(:block)
            push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = axes(A, $d)), newblock))
            block = newblock
        end
        # Push to inside innermost loop
        setξ = Expr(:(=), :ξ, Expr(:call, :+, Expr(:call, :exp, Expr(:call, :-, A, :vmax)), :ξ))
        push!(block.args, setξ)
        # Post-reduction
        setb = Expr(:(=), Bᵥ′, Expr(:call, :+, Expr(:call, :log, :ξ), :vmax))
        push!(rblock.args, setb)
        return quote
            Bᵥ = $Bᵥ
            @turbo $loops
            return B
        end
    else
        # Pre-reduction
        vmax = Expr(:(=), :vmax, Bᵥ′)
        ξ = Expr(:(=), :ξ, Expr(:call, :zero, Expr(:call, :eltype, :Bᵥ)))
        # Reduction loop
        block = Expr(:block)
        loops = Expr(:for, :($(Symbol(:i_, rinds[1])) = axes(A, $(rinds[1]))), block)
        for d ∈ @view(rinds[2:end])
            newblock = Expr(:block)
            push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = axes(A, $d)), newblock))
            block = newblock
        end
        # Push to inside innermost loop
        setξ = Expr(:(=), :ξ, Expr(:call, :+, Expr(:call, :exp, Expr(:call, :-, A, :vmax)), :ξ))
        push!(block.args, setξ)
        return quote
            Bᵥ = $Bᵥ
            $vmax
            $ξ
            @turbo $loops
            Bᵥ[] = log(ξ) + vmax
            return B
        end
    end
end

function branches_logsumexp_quote(N::Int, M::Int, D)
    static_dims = Int[]
    for m ∈ 1:M
        param = D.parameters[m]
        if param <: StaticInt
            new_dim = _dim(param)::Int
            push!(static_dims, new_dim)
        else
            # tuple of static dimensions
            t = Expr(:tuple)
            for n ∈ static_dims
                push!(t.args, :(StaticInt{$n}()))
            end
            q = Expr(:block, :(dimm = dims[$m]))
            qold = q
            # if-elseif statements
            ifsym = :if
            for n ∈ 1:N
                n ∈ static_dims && continue
                tc = copy(t)
                push!(tc.args, :(StaticInt{$n}()))
                qnew = Expr(ifsym, :(dimm == $n), :(return _vvlogsumexp!(B, A, $tc)))
                for r ∈ m+1:M
                    push!(tc.args, :(dims[$r]))
                end
                push!(qold.args, qnew)
                qold = qnew
                ifsym = :elseif
            end
            # else statement
            tc = copy(t)
            for r ∈ m+1:M
                push!(tc.args, :(dims[$r]))
            end
            push!(qold.args, Expr(:block, :(return _vvlogsumexp!(B, A, $tc))))
            return q
        end
    end
    return staticdim_logsumexp_quote(static_dims, N)
end

@generated function _vvlogsumexp!(B::AbstractArray{Tₒ, N}, A::AbstractArray{T, N}, dims::D) where {Tₒ, T, N, M, D<:Tuple{Vararg{Integer, M}}}
    branches_logsumexp_quote(N, M, D)
end
@generated function _vvlogsumexp!(B::AbstractArray{Tₒ, N}, A::AbstractArray{T, N}, dims::Tuple{}) where {Tₒ, T, N}
    :(copyto!(B, A); return B)
end

################
# Allocates twice, but oddly, sometimes slightly faster on large arrays.
# Keep as curiosity for further testing.

# function vvlogsumexp2(A::AbstractArray{T, N}, dims::NTuple{M, Int}) where {T, N, M}
#     Dᴬ = size(A)
#     Dᴮ′ = ntuple(d -> d ∈ dims ? 1 : Dᴬ[d], Val(N))
#     B = vvmaximum(A, dims)
#     C = similar(A, Base.promote_op(log, T), Dᴮ′)
#     _vvlogsumexp2!(C, A, B, dims)
#     return C
# end

# function staticdim_logsumexp2_quote(static_dims::Vector{Int}, N::Int)
#     A = Expr(:ref, :A, ntuple(d -> Symbol(:i_, d), N)...)
#     Bᵥ = Expr(:call, :view, :B)
#     Bᵥ′ = Expr(:ref, :Bᵥ)
#     Cᵥ = Expr(:call, :view, :C)
#     Cᵥ′ = Expr(:ref, :Cᵥ)
#     rinds = Int[]
#     nrinds = Int[]
#     for d = 1:N
#         if d ∈ static_dims
#             push!(Bᵥ.args, Expr(:call, :firstindex, :B, d))
#             push!(Cᵥ.args, Expr(:call, :firstindex, :C, d))
#             push!(rinds, d)
#         else
#             push!(Bᵥ.args, :)
#             push!(Cᵥ.args, :)
#             push!(nrinds, d)
#             push!(Bᵥ′.args, Symbol(:i_, d))
#             push!(Cᵥ′.args, Symbol(:i_, d))
#         end
#     end
#     reverse!(rinds)
#     reverse!(nrinds)
#     if !isempty(nrinds)
#         block = Expr(:block)
#         loops = Expr(:for, :($(Symbol(:i_, nrinds[1])) = indices((A, B, C), $(nrinds[1]))), block)
#         for d ∈ @view(nrinds[2:end])
#             newblock = Expr(:block)
#             push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = indices((A, B, C), $d)), newblock))
#             block = newblock
#         end
#         rblock = block
#         # Pre-reduction
#         vmax = Expr(:(=), :vmax, Bᵥ′)
#         push!(rblock.args, vmax)
#         ξ = Expr(:(=), :ξ, Expr(:call, :zero, Expr(:call, :eltype, :Cᵥ)))
#         push!(rblock.args, ξ)
#         # Reduction loop
#         for d ∈ rinds
#             newblock = Expr(:block)
#             push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = axes(A, $d)), newblock))
#             block = newblock
#         end
#         # Push to inside innermost loop
#         setξ = Expr(:(=), :ξ, Expr(:call, :+, Expr(:call, :exp, Expr(:call, :-, A, :vmax)), :ξ))
#         push!(block.args, setξ)
#         # Post-reduction
#         setc = Expr(:(=), Cᵥ′, Expr(:call, :+, Expr(:call, :log, :ξ), :vmax))
#         push!(rblock.args, setc)
#         return quote
#             Bᵥ = $Bᵥ
#             Cᵥ = $Cᵥ
#             @turbo $loops
#             return C
#         end
#     else
#         # Pre-reduction
#         vmax = Expr(:(=), :vmax, Bᵥ′)
#         ξ = Expr(:(=), :ξ, Expr(:call, :zero, Expr(:call, :eltype, :Cᵥ)))
#         # Reduction loop
#         block = Expr(:block)
#         loops = Expr(:for, :($(Symbol(:i_, rinds[1])) = axes(A, $(rinds[1]))), block)
#         for d ∈ @view(rinds[2:end])
#             newblock = Expr(:block)
#             push!(block.args, Expr(:for, :($(Symbol(:i_, d)) = axes(A, $d)), newblock))
#             block = newblock
#         end
#         # Push to inside innermost loop
#         setξ = Expr(:(=), :ξ, Expr(:call, :+, Expr(:call, :exp, Expr(:call, :-, A, :vmax)), :ξ))
#         push!(block.args, setξ)
#         return quote
#             Bᵥ = $Bᵥ
#             Cᵥ = $Cᵥ
#             $vmax
#             $ξ
#             @turbo $loops
#             Cᵥ[] = log(ξ) + vmax
#             return C
#         end
#     end
# end

# function branches_logsumexp2_quote(N::Int, M::Int, D)
#     static_dims = Int[]
#     for m ∈ 1:M
#         param = D.parameters[m]
#         if param <: StaticInt
#             new_dim = _dim(param)::Int
#             push!(static_dims, new_dim)
#         else
#             # tuple of static dimensions
#             t = Expr(:tuple)
#             for n ∈ static_dims
#                 push!(t.args, :(StaticInt{$n}()))
#             end
#             q = Expr(:block, :(dimm = dims[$m]))
#             qold = q
#             # if-elseif statements
#             ifsym = :if
#             for n ∈ 1:N
#                 n ∈ static_dims && continue
#                 tc = copy(t)
#                 push!(tc.args, :(StaticInt{$n}()))
#                 qnew = Expr(ifsym, :(dimm == $n), :(return _vvlogsumexp2!(C, A, B, $tc)))
#                 for r ∈ m+1:M
#                     push!(tc.args, :(dims[$r]))
#                 end
#                 push!(qold.args, qnew)
#                 qold = qnew
#                 ifsym = :elseif
#             end
#             # else statement
#             tc = copy(t)
#             for r ∈ m+1:M
#                 push!(tc.args, :(dims[$r]))
#             end
#             push!(qold.args, Expr(:block, :(return _vvlogsumexp2!(C, A, B, $tc))))
#             return q
#         end
#     end
#     return staticdim_logsumexp2_quote(static_dims, N)
# end

# @generated function _vvlogsumexp2!(C::AbstractArray{Tₒ, N}, A::AbstractArray{T, N}, B::AbstractArray{Tₘ, N}, dims::D) where {Tₒ, T, Tₘ, N, M, D<:Tuple{Vararg{Integer, M}}}
#     branches_logsumexp2_quote(N, M, D)
# end
# @generated function _vvlogsumexp2!(C::AbstractArray{Tₒ, N}, A::AbstractArray{T, N}, B::AbstractArray{Tₘ, N}, dims::Tuple{}) where {Tₒ, T, Tₘ, N}
#     :(copyto!(C, A); return C)
# end

