#' A grouped data frame.
#'
#' The easiest way to create a grouped data frame is to call the `group_by()`
#' method on a data frame or tbl: this will take care of capturing
#' the unevaluated expressions for you.
#'
#' @keywords internal
#' @param data a tbl or data frame.
#' @param vars a character vector or a list of [name()]
#' @param drop deprecated
#' @export
grouped_df <- function(data, vars, drop) {
  if (length(vars) == 0) {
    return(tbl_df(data))
  }
  assert_that(
    is.data.frame(data),
    (is.list(vars) && all(sapply(vars, is.name))) || is.character(vars)
  )
  if (!missing(drop)) {
    warning("`drop` is deprecated")
  }
  if (is.list(vars)) {
    vars <- deparse_names(vars)
  }
  grouped_df_impl(data, unname(vars))
}

setOldClass(c("grouped_df", "tbl_df", "tbl", "data.frame"))

#' @rdname grouped_df
#' @export
is.grouped_df <- function(x) inherits(x, "grouped_df")
#' @rdname grouped_df
#' @export
is_grouped_df <- is.grouped_df

#' @export
tbl_sum.grouped_df <- function(x) {
  grps <- n_groups(x)
  c(
    NextMethod(),
    c("Groups" = paste0(commas(group_vars(x)), " [", big_mark(grps), "]"))
  )
}

#' @export
group_size.grouped_df <- function(x) {
  group_size_grouped_cpp(x)
}

#' @export
n_groups.grouped_df <- function(x) {
  nrow(group_data(x))
}

#' @export
groups.grouped_df <- function(x) {
  syms(group_vars(x))
}

#' @export
group_vars.grouped_df <- function(x) {
  groups <- group_data(x)
  if (is.character(groups)) {
    # lazy grouped
    groups
  } else if (is.data.frame(groups)) {
    # resolved, extract from the names of the data frame
    head(names(groups), -1L)
  } else if (is.list(groups)) {
    # Need this for compatibility with existing packages that might
    # use the old list of symbols format
    map_chr(groups, as_string)
  }
}

#' @export
as.data.frame.grouped_df <- function(x, row.names = NULL,
                                     optional = FALSE, ...) {
  x <- ungroup(x)
  class(x) <- "data.frame"
  x
}

#' @export
as_data_frame.grouped_df <- function(x, ...) {
  x <- ungroup(x)
  class(x) <- c("tbl_df", "tbl", "data.frame")
  x
}

#' @export
ungroup.grouped_df <- function(x, ...) {
  ungroup_grouped_df(x)
}

#' @export
`[.grouped_df` <- function(x, i, j, ...) {
  y <- NextMethod()

  group_names <- group_vars(x)

  if (!all(group_names %in% names(y))) {
    tbl_df(y)
  } else {
    grouped_df(y, group_names)
  }
}

#' @method rbind grouped_df
#' @export
rbind.grouped_df <- function(...) {
  bind_rows(...)
}

#' @method cbind grouped_df
#' @export
cbind.grouped_df <- function(...) {
  bind_cols(...)
}

# One-table verbs --------------------------------------------------------------

# see arrange.r for arrange.grouped_df

.select_grouped_df <- function(.data, ..., notify = TRUE) {
  # Pass via splicing to avoid matching vars_select() arguments
  vars <- tidyselect::vars_select(names(.data), !!!quos(...))
  vars <- ensure_group_vars(vars, .data, notify = notify)
  select_impl(.data, vars)
}

#' @export
select.grouped_df <- function(.data, ...) {
  .select_grouped_df(.data, !!!quos(...), notify = TRUE)
}
#' @export
select_.grouped_df <- function(.data, ..., .dots = list()) {
  dots <- compat_lazy_dots(.dots, caller_env(), ...)
  select.grouped_df(.data, !!!dots)
}

ensure_group_vars <- function(vars, data, notify = TRUE) {
  group_names <- group_vars(data)
  missing <- setdiff(group_names, vars)

  if (length(missing) > 0) {
    if (notify) {
      inform(glue(
        "Adding missing grouping variables: ",
        paste0("`", missing, "`", collapse = ", ")
      ))
    }
    vars <- c(set_names(missing, missing), vars)
  }

  vars
}

#' @export
rename.grouped_df <- function(.data, ...) {
  vars <- tidyselect::vars_rename(names(.data), ...)
  select_impl(.data, vars)
}
#' @export
rename_.grouped_df <- function(.data, ..., .dots = list()) {
  dots <- compat_lazy_dots(.dots, caller_env(), ...)
  rename(.data, !!!dots)
}


# Do ---------------------------------------------------------------------------

#' @importFrom tidyselect last_col
#' @export
do.grouped_df <- function(.data, ...) {
  index <- group_rows(.data)
  labels <- select(group_data(.data), -last_col())

  # Create ungroup version of data frame suitable for subsetting
  group_data <- ungroup(.data)

  args <- quos(...)
  named <- named_args(args)
  env <- child_env(NULL)

  n <- length(index)
  m <- length(args)

  # Special case for zero-group/zero-row input
  if (n == 0) {
    if (named) {
      out <- rep_len(list(list()), length(args))
      out <- set_names(out, names(args))
      out <- label_output_list(labels, out, groups(.data))
    } else {
      env_bind(.env = env, . = group_data, .data = group_data)
      out <- overscope_eval_next(env, args[[1]])[0, , drop = FALSE]
      out <- label_output_dataframe(labels, list(list(out)), groups(.data))
    }
    return(out)
  }

  # Add pronouns with active bindings that resolve to the current
  # subset. `_i` is found in environment of this function because of
  # usual scoping rules.
  group_slice <- function(value) {
    if (missing(value)) {
      group_data[index[[`_i`]] + 1L, , drop = FALSE]
    } else {
      group_data[index[[`_i`]] + 1L, ] <<- value
    }
  }
  env_bind_fns(.env = env, . = group_slice, .data = group_slice)

  overscope <- new_overscope(env)
  on.exit(overscope_clean(overscope))

  out <- replicate(m, vector("list", n), simplify = FALSE)
  names(out) <- names(args)
  p <- progress_estimated(n * m, min_time = 2)

  for (`_i` in seq_len(n)) {
    for (j in seq_len(m)) {
      out[[j]][`_i`] <- list(overscope_eval_next(overscope, args[[j]]))
      p$tick()$print()
    }
  }

  if (!named) {
    label_output_dataframe(labels, out, groups(.data))
  } else {
    label_output_list(labels, out, groups(.data))
  }
}
#' @export
do_.grouped_df <- function(.data, ..., env = caller_env(), .dots = list()) {
  dots <- compat_lazy_dots(.dots, env, ...)
  do(.data, !!!dots)
}

# Set operations ---------------------------------------------------------------

#' @export
distinct.grouped_df <- function(.data, ..., .keep_all = FALSE) {
  dist <- distinct_vars(
    .data,
    vars = quos(...),
    group_vars = group_vars(.data),
    .keep_all = .keep_all
  )
  vars <- match_vars(dist$vars, dist$data)
  keep <- match_vars(dist$keep, dist$data)
  out <- distinct_impl(dist$data, vars, keep)
  grouped_df(out, groups(.data))
}
#' @export
distinct_.grouped_df <- function(.data, ..., .dots = list(), .keep_all = FALSE) {
  dots <- compat_lazy_dots(.dots, caller_env(), ...)
  distinct(.data, !!!dots, .keep_all = .keep_all)
}
