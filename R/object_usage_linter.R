#' @describeIn linters checks that closures have the proper usage using
#' \code{\link[codetools]{checkUsage}}.  Note this runs
#' \code{\link[base]{eval}} on the code, so do not use with untrusted code.
#' @export
object_usage_linter <-  function(source_file) {
  # we need to evaluate each expression in order to use checkUsage on it.

  pkg_name <- pkg_name(find_package(dirname(source_file$filename)))
  if (!is.null(pkg_name)) {
    parent_env <- try(getNamespace(pkg_name), silent = TRUE)
  }
  if (is.null(pkg_name) || inherits(parent_env, "try-error")) {
    parent_env <- globalenv()
  }
  env <- new.env(parent=parent_env)

  globals <- mget(".__global__",
    parent_env,
    ifnotfound = list(NULL))$`.__global__`

  mapply(assign, globals, MoreArgs=list(value = function(...) NULL, envir = env))

  # add file locals to the environment
  try(eval(source_file$parsed_content, envir = env), silent = TRUE)

  all_globals <- unique(recursive_ls(env))

  lapply(ids_with_token(source_file, rex(start, "FUNCTION"), fun=re_matches),
    function(loc) {
      id <- source_file$parsed_content$id[loc]

      parent_ids <- parents(source_file$parsed_content, id, simplify = FALSE)

      # not a top level function, so just return.
      if (length(parent_ids) > 3L) {
        return(NULL)
      }
      #text <- paste0(collapse = "\n", source_file$lines)
      suppressWarnings(
        suppressMessages(
          fun <- try(eval(
              parse(
                text=source_file$content,
                keep.source = TRUE
                ),
              envir=env), silent = TRUE)
        )
      )

      if (!inherits(fun, "try-error")) {
        res <- parse_check_usage(fun)

        locals <- codetools::findFuncLocals(formals(fun), body(fun))

        both <- c(locals, names(formals(fun)), all_globals)

        lapply(which(!is.na(res$message)),
          function(row_num) {
            row <- res[row_num, ]

            # if a no visible binding message suggest an alternative
            if (re_matches(row$message,
                rex("no visible"))) {

              suggestion <- try(both[stringdist::amatch(row$name, both, maxDist = 2)], silent = TRUE)

              if (!inherits(suggestion, "try-error") && !is.na(suggestion)) {
                row$message <- paste0(row$message, ", Did you mean '", suggestion, "'?")
              }

            }

            org_line_num <- as.integer(row$line_number) + as.integer(names(source_file$lines)[1]) - 1L

            line <- source_file$lines[as.character(org_line_num)]

            row$name <- re_substitutes(row$name, rex("<-"), "")

            location <- re_matches(line,
              rex(row$name),
              locations = TRUE)

            Lint(
              filename = source_file$filename,
              line_number = org_line_num,
              column_number = location$start,
              type = "warning",
              message = row$message,
              line = line,
              ranges = list(c(location$start, location$end)),
              linter = "object_usage_linter"
              )
          })
      }
    })
}

parse_check_usage <- function(expression) {

  vals <- list()

  report <- function (x) {
    vals[[length(vals) + 1L]] <<- x
  }

  try(codetools::checkUsage(expression, report = report))

  function_name <- rex(anything, ": ")
  line_info <- rex(" ", anything, ":", capture(name = "line_number", digits), ")")

  res <- re_matches(vals,
    rex(function_name,
      capture(name = "message", anything,
        one_of(quote, "\u2018"), capture(name = "name", anything), one_of(quote, "\u2019"),
        anything),
      line_info))

  missing <- is.na(res$message)
  if (any(missing)) {
    res[missing, ] <- re_matches(vals[missing],
      rex(function_name,
        capture(name = "message",
          "possible error in ", capture(name = "name", anything), ": ", anything
          ),
          line_info))
  }

  res
}
