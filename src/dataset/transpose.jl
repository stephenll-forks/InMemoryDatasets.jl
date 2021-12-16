# a helper function that checks if there is enough memory for the output data frame
#  If type is not Number, probably something is wrong about setting the variables and it is better to be conservative. here 10^7 threshhold is arbitarary
_check_allocation_limit(T, rows, cols) = T <: Number ? sizeof(T)*rows*cols / Base.Sys.total_memory() : rows*cols/10^7

_default_renamecolid_function_withoutid(x, y) = "_c" * string(x)
_default_renamecolid_function_withid(x, y) = identity(string(values(x)))
_default_renamerowid_function(x) = identity(x)
# handling simplest case
function _simple_ds_transpose!(outx, inx, i)
    @views copy!(outx[i,:], inx)
end

function _generate_col_row_names(renamecolid, renamerowid, ids, dsnames; max_length = 0)
    local new_col_names
    try
        new_col_names = map(x -> renamecolid(x, dsnames), ids)
    catch e
        if (e isa MethodError)
            new_col_names = map(renamecolid, ids)
        else
            rethrow(e)
        end
    end
    row_names = map(renamerowid, dsnames)
    row_names = allowmissing(row_names)
    r_n_l = length(row_names)
    if r_n_l < max_length
        resize!(row_names, max_length)
        for i in r_n_l+1:max_length
            row_names[i] = missing
        end
    end
    (new_col_names, row_names)
end

function _simple_transpose_ds_generate(T, in_cols, row_names_length, new_col_names, variable_name, threads)
    outputmat = Matrix{T}(undef, row_names_length, length(new_col_names))
    if threads
        Threads.@threads for i in 1:length(in_cols)
            _simple_ds_transpose!(outputmat, in_cols[i], i)
        end
    else
        for i in 1:length(in_cols)
            _simple_ds_transpose!(outputmat, in_cols[i], i)
        end
    end
    outputmat

end


function _find_id_unique_values(ds, ididx::MultiColumnIndex, perms; mapformats = true)
    groups, gslots, ngroups = _gather_groups(ds[perms, ididx], :, nrow(ds) < typemax(Int32) ? Val(Int32) : Val(Int64), mapformats = mapformats)
    res = falses(nrow(ds))
    seen_groups = falses(ngroups)
    @inbounds for i in 1:length(res)
        !seen_groups[groups[i]] ? (seen_groups[groups[i]] = true; res[i] = true) : nothing
    end
    return groups, res
end
_find_id_unique_values(ds, ididx::ColumnIndex, perms; mapformats = true) = _find_id_unique_values(ds, [ididx], perms; mapformats = mapformats)

"""
    transpose(ds::Dataset, cols;
        id = nothing,
        renamecolid = (x -> "_c" * string(x)),
        renamerowid = identity,
        variable_name = "_variables_",
        default = missing,
        mapformats = true,
        threads = true)

transpose `ds[!, cols]`. When `id` is set, the values of `ds[!, id]` will be used to label the columns in the new data set. The function uses the `renamecolid` function to generate the new columns labels. The `renamerowid` function is applied to stringified names of `ds[!, cols]` and these are attached to the output as a new column with the label `variable_name`. When a grouped dataset (e.g. by using `groupby!(ds, gcols)`, or `groupby(ds, gcols)`) passed as the first argument the transposing is done within each group constructed by grouping columns. If the number of rows in a group is smaller than other groups, the extra columns for that group in the output data frame is filled with `missing` by default, however, the default value can be changed by passing `default = ` argument.

When `cols` is a Tuple of column indices, the transposing is done for each set of indices and at the end all transposed columns are horizontally concatenated. In this case, the `variable_name` keyword argument is set to `nothing`.

* `renamecolid`: When `id` is not set, the argument to `renamecolid` must be an `Int`. And when `id` is set, the `renamecolid` will be applied to each row of `ds[!, id]` as Tuple.
* When `id` is set, `renamecolid` is defined as `x -> identity(string(values(x)))`
* By default, `transpose` uses the formatted value for the id variables, to change this the `mapformats = false` can be used.
* When `threads = true`, `transpose` uses all available cores to `Julia` to do the computations.

```jldoctest
julia> ds = Dataset(x1 = [1,2,3,4], x2 = [1,4,9,16])
4×2 Dataset
 Row │ x1        x2
     │ identity  identity
     │ Int64?    Int64?
─────┼────────────────────
   1 │        1         1
   2 │        2         4
   3 │        3         9
   4 │        4        16

julia> transpose(ds, [:x1,:x2])
2×5 Dataset
Row │ _variables_   _c1       _c2       _c3       _c4
    │ identity      identity  identity  identity  identity
    │ Characters…?  Int64?    Int64?    Int64?    Int64?
────┼──────────────────────────────────────────────────────
  1 │ x1                   1         2         3         4
  2 │ x2                   1         4         9        16

julia> pop = Dataset(country = ["c1","c1","c2","c2","c3","c3"],
                       sex = repeat(["male", "female"],3),
                       pop_2000 = [100, 120, 150, 155, 170, 190],
                       pop_2010 = [110, 120, 155, 160, 178, 200],
                       pop_2020 = [115, 130, 161, 165, 180, 203])
6×5 Dataset
Row │ country     sex         pop_2000  pop_2010  pop_2020
    │ identity    identity    identity  identity  identity
    │ Characte…?  Characte…?  Int64?    Int64?    Int64?
────┼──────────────────────────────────────────────────────
  1 │ c1          male             100       110       115
  2 │ c1          female           120       120       130
  3 │ c2          male             150       155       161
  4 │ c2          female           155       160       165
  5 │ c3          male             170       178       180
  6 │ c3          female           190       200       203

julia> groupby!(pop, :country);
julia> transpose(pop, r"pop_",
                id = :sex, variable_name = "year",
                renamerowid = x -> replace(x, "pop_" => ""),
                renamecolid = x -> x * "_pop")
9×4 Dataset
 Row │ country     year        male_pop  female_pop
     │ identity    identity    identity  identity
     │ Characte…?  Characte…?  Int64?    Int64?
─────┼──────────────────────────────────────────────
   1 │ c1          2000             100         120
   2 │ c1          2010             110         120
   3 │ c1          2020             115         130
   4 │ c2          2000             150         155
   5 │ c2          2010             155         160
   6 │ c2          2020             161         165
   7 │ c3          2000             170         190
   8 │ c3          2010             178         200
   9 │ c3          2020             180         203

```
"""
Base.transpose(::Dataset, cols; [id , renamecolid , renamerowid , variable_name, default, threads, mapformats])

function ds_transpose(ds, cols::Union{Tuple, MultiColumnIndex}; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = "_variables_", threads = true, mapformats = true)
    if cols isa Tuple
        tcols = [cols[j] isa ColumnIndex ? index(ds)[[cols[j]]] : index(ds)[cols[j]] for j in 1:length(cols)]
    else
        tcols = [index(ds)[cols]]
    end
    max_num_col = maximum(length, tcols)
    if variable_name isa AbstractString || variable_name isa Symbol || variable_name === nothing
        var_name = repeat([variable_name], length(tcols))
    elseif variable_name isa AbstractVector
        var_name = variable_name
        @assert length(var_name) == length(tcols)
    else
        throw(ArgumentError("`variable_name` must be a string, symbol, nothing, or a vector of them"))
    end
    if id !== nothing
        ididx = index(ds)[id]

        if renamecolid === nothing
            renamecolid = _default_renamecolid_function_withid
        end
        ids_refs, unique_loc  = _find_id_unique_values(ds, ididx, _get_perms(ds); mapformats = mapformats)

        if length(ididx) == 1
            unique_ids = getindex(parent(ds), view(_get_perms(ds), unique_loc), ididx[1]; mapformats = mapformats)
        else
            #TODO not very good way to do this
            unique_ids = Tables.rowtable(Dataset([getindex(ds, view(_get_perms(ds), unique_loc), ididx[k], mapformats = mapformats) for k in 1:length(ididx)], :auto, copycols = false))
        end
        @assert (size(unique_ids,1)) == nrow(ds) "Duplicate ids are not allowed."
    end


    local newds
    for j in 1:length(tcols)
        sel_cols = tcols[j]
        ECol = view(_columns(ds), sel_cols)
        T = mapreduce(eltype, promote_type, ECol)
        # make sure the new columns have missing support by default
        T = Union{Missing, T}

        if id === nothing
            if renamecolid === nothing
                renamecolid = _default_renamecolid_function_withoutid
            end
            new_col_names, row_names = _generate_col_row_names(renamecolid, renamerowid, 1:nrow(ds), names(ds)[sel_cols], max_length = max_num_col)
        else

            new_col_names, row_names = _generate_col_row_names(renamecolid, renamerowid, unique_ids, names(ds)[sel_cols], max_length = max_num_col)
        end

        outputmat = _simple_transpose_ds_generate(T, ECol, max_num_col, new_col_names, variable_name, threads)
        if j == 1
            newds = Dataset(outputmat, new_col_names)
            if var_name[j] !== nothing
                new_var_label = Symbol(var_name[j])
                newds = insertcols!(newds, 1,  new_var_label => row_names, unsupported_copy_cols = false)
            end
        else
            ds2 = Dataset(outputmat, new_col_names)
            u = add_names(index(newds), index(ds2), makeunique=true)
            for i in 1:length(u)
                newds[!, u[i]] = ds2[!, i].val
            end
            if var_name[j] !== nothing
                new_var_label = Symbol(var_name[j])
                insertcols!(newds, j, new_var_label => row_names, unsupported_copy_cols = false, makeunique = true)
            end
        end
    end
    newds
end


# groupby case
function _fill_onecol_for_tr!(y, x, ntimes, perms)
    for i in 1:length(perms)
        fill!(view(y, (i-1)*ntimes+1:(i*ntimes)), x[perms[i]])
    end
end
function _fill_onecol_for_tr_threaded!(y, x, ntimes, perms)
    Threads.@threads for i in 1:length(perms)
        fill!(view(y, (i-1)*ntimes+1:(i*ntimes)), x[perms[i]])
    end
end

function _fill_row_names!(res, row_names, ntimes)
    n = length(row_names)
    for i in 1:ntimes
        @views copy!(res[(i-1)*n+1:i*n], row_names)
    end
    res
end

function _fill_gcol!(res, ds, gcolindex, colsidx_length, perms, nrows, threads)
    ntimes = colsidx_length
    totalrow = nrows * ntimes
    for i in 1:length(gcolindex)
        _tmp = allocatecol(ds[!,gcolindex[i]].val, totalrow)
        push!(res, _tmp)
        if DataAPI.refpool(res[i]) !== nothing
            if threads
                _fill_onecol_for_tr_threaded!(res[i].refs, _columns(ds)[gcolindex[i]].refs, ntimes, perms)
            else
                _fill_onecol_for_tr!(res[i].refs, _columns(ds)[gcolindex[i]].refs, ntimes, perms)
            end
        else
            if threads
                _fill_onecol_for_tr_threaded!(res[i], _columns(ds)[gcolindex[i]], ntimes, perms)
            else
                _fill_onecol_for_tr!(res[i], _columns(ds)[gcolindex[i]], ntimes, perms)
            end
        end
    end
    res
end

function _fill_col_val_f_barrier_threaded!(res, xvals, perms, ntimes, max_num_col, ds_n_row, j)
    Threads.@threads for i in 1:ds_n_row
        res[(i-1)*max_num_col+j] = xvals[perms[i]]
    end
end
function _fill_col_val_f_barrier!(res, xvals, perms, ntimes, max_num_col, ds_n_row, j)
    for i in 1:ds_n_row
        res[(i-1)*max_num_col+j] = xvals[perms[i]]
    end
end


function _fill_col_val!(res, in_cols, ntimes, max_num_col, ds_n_row, perms, threads)
    for j in 1:ntimes
        if threads
            _fill_col_val_f_barrier_threaded!(res, in_cols[j], perms, ntimes, max_num_col, ds_n_row, j)
        else
            _fill_col_val_f_barrier!(res, in_cols[j], perms, ntimes, max_num_col, ds_n_row, j)
        end
    end
end


function fast_stack_gcols(T, ds, in_cols, colsidx_length, gcolsidx, threads)
    # construct group columns
    g_array = AbstractArray[]
    _fill_gcol!(g_array, parent(ds), gcolsidx, colsidx_length, _get_perms(ds), nrow(ds), threads)
    ds1 = Dataset(g_array, _names(ds)[gcolsidx], copycols = false)
    ds1
end

function _extend_repeat_row_names!(row_names, max_num_col)
    r_n_l = length(row_names)
    if r_n_l < max_num_col
        resize!(row_names, max_num_col)
        for i in r_n_l+1:max_num_col
            row_names[i] = missing
        end
    end
    row_names
end


function _obtain_maximum_groups_size(starts, nrows)
    maxvalue = nrows - starts[end] + 1
    for i in (length(starts) - 1):-1:1
        diffvalue = starts[i + 1] - starts[i]
        if diffvalue > maxvalue
            maxvalue = diffvalue
        end
    end
    return maxvalue
end

function _fill_one_col_transpose!(outputmat, xval, starts, perms, n_row_names, row, ngrps)
    for g in 1:ngrps
        lo = starts[g]
        g == ngrps ? hi = length(xval) : hi = starts[g+1] - 1
        cnt = 1
        for i in lo:hi
            outputmat[cnt][(g - 1) * n_row_names + row] = xval[perms[lo + cnt - 1]]
            cnt += 1
        end
    end
end
function _fill_one_col_transpose_threaded!(outputmat, xval, starts, perms, n_row_names, row, ngrps)
    Threads.@threads for g in 1:ngrps
        lo = starts[g]
        g == ngrps ? hi = length(xval) : hi = starts[g+1] - 1
        cnt = 1
        for i in lo:hi
            outputmat[cnt][(g - 1) * n_row_names + row] = xval[perms[lo + cnt - 1]]
            cnt += 1
        end
    end
end

function _fill_one_col_transpose_id!(outputmat, xval, starts, perms, n_row_names, _is_cell_filled, ids, row, ngrps)
    for g in 1:ngrps
        lo = starts[g]
        g == ngrps ? hi = length(xval) : hi = starts[g+1] - 1
        counter = 1
        for i in lo:hi
            cnt = ids[i]
            _row_ = (g - 1) * n_row_names + row
            if _is_cell_filled[_row_, cnt]
                throw(AssertionError("Duplicate id within a group is not allowed"))
            else
                outputmat[cnt][_row_] = xval[perms[lo + counter - 1]]
                _is_cell_filled[_row_, cnt] = true
                counter += 1
            end
        end
    end
end
function _fill_one_col_transpose_id_threaded!(outputmat, xval, starts, perms, n_row_names, _is_cell_filled, ids, row, ngrps)
    Threads.@threads for g in 1:ngrps
        lo = starts[g]
        g == ngrps ? hi = length(xval) : hi = starts[g+1] - 1
        counter = 1
        for i in lo:hi
            cnt = ids[i]
            _row_ = (g - 1) * n_row_names + row
            if _is_cell_filled[_row_, cnt]
                throw(AssertionError("Duplicate id within a group is not allowed"))
            else
                outputmat[cnt][_row_] = xval[perms[lo + counter - 1]]
                _is_cell_filled[_row_, cnt] = true
                counter += 1
            end
        end
    end
end


function update_outputmat!(outputmat, x, starts, perms, n_row_names, threads)
    if threads
        for j in 1:length(x)
            _fill_one_col_transpose_threaded!(outputmat, x[j], starts, perms, n_row_names, j, length(starts))
        end
    else
        for j in 1:length(x)
            _fill_one_col_transpose!(outputmat, x[j], starts, perms, n_row_names, j, length(starts))
        end
    end
end

function update_outputmat!(outputmat, x, starts, perms, ids, n_row_names, _is_cell_filled, threads)
    if threads
        for j in 1:length(x)
            _fill_one_col_transpose_id_threaded!(outputmat, x[j], starts, perms, n_row_names, _is_cell_filled, ids, j, length(starts))
        end
    else
        for j in 1:length(x)
            _fill_one_col_transpose_id!(outputmat, x[j], starts, perms, n_row_names, _is_cell_filled, ids, j, length(starts))
        end
    end
end

function _fill_outputmat_withoutid(T, in_cols, ds, starts, perms, new_col_names, row_names_length, threads; default_fill = missing)

    @assert _check_allocation_limit(nonmissingtype(T), row_names_length*_ngroups(ds), length(new_col_names)) < 1.0 "The output data frame is huge and there is not enough resource to allocate it."
    CT = promote_type(T, typeof(default_fill))
    outputmat = [fill!(Vector{CT}(undef, row_names_length*_ngroups(ds)), default_fill) for _ in 1:length(new_col_names)]
    update_outputmat!(outputmat, in_cols, starts, perms, row_names_length, threads)

    outputmat
end

function _fill_outputmat_withid(T, in_cols, ds, starts, perms, ids, new_col_names, row_names_length, threads; default_fill = missing)

    @assert _check_allocation_limit(nonmissingtype(T), row_names_length*_ngroups(ds), length(new_col_names)) < 1.0 "The output data frame is huge and there is not enough resource to allocate it."
    CT = promote_type(T, typeof(default_fill))
    outputmat = [fill!(Vector{CT}(undef, row_names_length*_ngroups(ds)), default_fill) for _ in 1:length(new_col_names)]

    _is_cell_filled = zeros(Bool, row_names_length*_ngroups(ds), length(new_col_names))

    update_outputmat!(outputmat, in_cols, starts, perms, ids, row_names_length, _is_cell_filled, threads)

    outputmat
end

function ds_transpose(ds::Union{Dataset, GroupBy, GatherBy}, cols::Union{Tuple, MultiColumnIndex}, gcols::MultiColumnIndex; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = "_variables_", default_fill = missing, threads = true, mapformats = true)
    if cols isa Tuple
        tcols = [cols[j] isa ColumnIndex ? index(ds)[[cols[j]]] : index(ds)[cols[j]] for j in 1:length(cols)]
    else
        tcols = [index(ds)[cols]]
    end
    max_num_col = maximum(length, tcols)
    gcolsidx = gcols
    if variable_name isa AbstractString || variable_name isa Symbol || variable_name === nothing
        var_name = repeat([variable_name], length(tcols))
    elseif variable_name isa AbstractVector
        var_name = variable_name
        @assert length(var_name) == length(tcols)
    else
        throw(ArgumentError("`variable_name` must be a string, symbol, nothing, or a vector of them"))
    end
    local outds

    need_fast_stack = false
    if _ngroups(ds) == nrow(ds)
        need_fast_stack = true
    end
    if need_fast_stack && id === nothing
        if renamecolid === nothing
            renamecolid = _default_renamecolid_function_withoutid
        end
        # fast_stack path, while keeping the row order consistent
        for j in 1:length(tcols)
            sel_cols = tcols[j]
            ECol = view(_columns(ds), sel_cols)

            T = mapreduce(eltype, promote_type, ECol)
            T = Union{T, Missing}

            if j == 1
                outds = fast_stack_gcols(T, ds, ECol, max_num_col, gcolsidx, threads)
                for j in 1:length(gcolsidx)
                    setformat!(outds, j => getformat(parent(ds), gcolsidx[j]))
                end
            end
            if var_name[j] !== nothing
                _repeat_row_names = allowmissing(PooledArray(renamerowid.(names(ds, sel_cols))))
                _extend_repeat_row_names!(_repeat_row_names, max_num_col)
                _repeat_row_names.refs = repeat(_repeat_row_names.refs, nrow(ds))
                new_var_label = Symbol(var_name[j])
                insertcols!(outds, length(gcolsidx)+j, new_var_label => _repeat_row_names, unsupported_copy_cols = false, makeunique = true)
            end
            res = Vector{Union{Missing, T}}(undef, nrow(ds) * max_num_col)
            _fill_col_val!(res, ECol, length(sel_cols), max_num_col, nrow(ds), _get_perms(ds), threads)
            local new_col_id
            try
                new_col_id = Symbol(renamecolid(1, names(ds, sel_cols)))
            catch e
                if (e isa MethodError)
                    new_col_id = Symbol(renamecolid(1))
                else
                    rethrow(e)
                end
            end
            insertcols!(outds, ncol(outds)+1, new_col_id => res, unsupported_copy_cols = false, makeunique = true)
        end
        return outds

    end
    if id !== nothing
        ididx = index(ds)[id]
        if renamecolid === nothing
            renamecolid = _default_renamecolid_function_withid
        end
        ids_refs, unique_loc  = _find_id_unique_values(parent(ds), ididx, _get_perms(ds); mapformats = mapformats)

        # we assume the unique function keep the same order as original data, which is the case sofar
        if length(ididx) == 1
            unique_ids = getindex(parent(ds), view(_get_perms(ds), unique_loc), ididx[1], mapformats = mapformats)
        else
            #TODO not very good way to do this
            unique_ids = Tables.rowtable(Dataset([getindex(parent(ds), view(_get_perms(ds), unique_loc), ididx[k], mapformats = mapformats) for k in 1:length(ididx)], :auto, copycols = false))
        end

        out_ncol = length(unique_ids)
    end

    for j in 1:length(tcols)
        sel_cols = tcols[j]
        ECol = view(_columns(ds), sel_cols)

        T = mapreduce(eltype, promote_type, ECol)
        T = Union{T, Missing}

        if id === nothing
            if renamecolid === nothing
                renamecolid = _default_renamecolid_function_withoutid
            end

            out_ncol = _obtain_maximum_groups_size(view(_group_starts(ds), 1:_ngroups(ds)), nrow(ds))
            new_col_names, row_names = _generate_col_row_names(renamecolid, renamerowid, 1:out_ncol, names(ds)[sel_cols], max_length = max_num_col)
            outputmat = _fill_outputmat_withoutid(T, ECol, ds, view(_group_starts(ds), 1:_ngroups(ds)), _get_perms(ds), new_col_names, max_num_col, threads; default_fill = default_fill)
        else

            new_col_names, row_names = _generate_col_row_names(renamecolid, renamerowid, unique_ids, names(ds)[sel_cols], max_length = max_num_col)
            outputmat = _fill_outputmat_withid(T, ECol, ds, view(_group_starts(ds), 1:_ngroups(ds)),  _get_perms(ds), ids_refs, new_col_names, max_num_col, threads; default_fill = default_fill)
        end
        # rows_with_group_info = _find_group_row(gds)
        new_var_label = Symbol(var_name[j])
        if j == 1
            g_array = AbstractArray[]
            _fill_gcol!(g_array, parent(ds), gcolsidx, max_num_col, view(_get_perms(ds), view(_group_starts(ds), 1:_ngroups(ds))), _ngroups(ds), threads)
            outds = Dataset(g_array, _names(ds)[gcolsidx], copycols = false)
            for j in 1:length(gcolsidx)
                setformat!(outds, j => getformat(parent(ds), gcolsidx[j]))
            end
        end

        # _repeat_row_names = Vector{eltype(row_names)}(undef, _ngroups(ds)*length(colsidx))
        # _fill_row_names!(_repeat_row_names, row_names, _ngroups(ds))
        if var_name[j] !== nothing
            _repeat_row_names = allowmissing(PooledArray(row_names))
            _repeat_row_names.refs = repeat(_repeat_row_names.refs, _ngroups(ds))
            insertcols!(outds, length(gcolsidx)+j, new_var_label => _repeat_row_names, unsupported_copy_cols = false, makeunique = true)
        end
        outds2 = Dataset(outputmat, new_col_names, copycols = false)

        for j in 1:ncol(outds2)
            push!(_columns(outds), _columns(outds2)[j])
        end
        merge!(index(outds), index(outds2), makeunique = true)
    end
    outds
end

function Base.transpose(ds::AbstractDataset, cols::MultiColumnIndex; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = "_variables_", default = missing, threads = true, mapformats = true)
    if !isgrouped(ds)
        ds_transpose(ds, cols; id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, mapformats = mapformats)
    else
        ds_transpose(ds, cols, _groupcols(ds); id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, default_fill = default, mapformats = mapformats)
    end
end

Base.transpose(ds::Union{GroupBy, GatherBy}, cols::MultiColumnIndex; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = "_variables_", default = missing, threads = true, mapformats = true) =
    ds_transpose(ds, cols, _groupcols(ds); id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, default_fill = default, mapformats = mapformats)

Base.transpose(ds::Union{GatherBy, GroupBy, AbstractDataset}, col::ColumnIndex; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = "_variables_", default = missing, threads = true, mapformats = true) =
    transpose(ds, [col]; id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, default = default, threads = threads, mapformats = mapformats)

function Base.transpose(ds::AbstractDataset, cols::Tuple; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = nothing, default = missing, threads = true, mapformats = true)
    if !isgrouped(ds)
        ds_transpose(ds, cols; id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, mapformats = mapformats)
    else
        ds_transpose(ds, cols, _groupcols(ds); id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, default_fill = default, mapformats = mapformats)
    end
end

Base.transpose(ds::Union{GroupBy, GatherBy}, cols::Tuple; id = nothing, renamecolid = nothing, renamerowid = _default_renamerowid_function, variable_name = nothing, default = missing, threads = true, mapformats = true) =
    ds_transpose(ds, cols, _groupcols(ds); id = id, renamecolid = renamecolid, renamerowid = renamerowid, variable_name = variable_name, threads = threads, default_fill = default, mapformats = mapformats)
