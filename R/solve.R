
#' The dependency solver
#'
#' The dependency solver takes the resolution information, and works out
#' the exact versions of each package that must be installed, such that
#' version and other requirements are satisfied.
#'
#' ## Solution policies
#'
#' The dependency solver currently supports two policies: `lazy` and
#' `upgrade`. The `lazy` policy prefers to minimize installation time,
#' and it does not perform package upgrades, unless version requirements
#' require them. The `upgrade` policy prefers to update all package to
#' their latest possible versions, but it still considers that version
#' requirements.
#'
#' ## The integer problem
#'
#' Solving the package dependencies requires solving an integer linear
#' problem (ILP). This subsection briefly describes how the problem is
#' represented as an integer problem, and what the solution policies
#' exactly mean.
#'
#' Every row of the package resolution is a candidate for the dependency
#' solver. In the integer problem, every candidate corresponds to a binary
#' variable. This is 1 if that candidate is selected as part of the
#' solution, and 0 otherwise.
#'
#' The objective of the ILP minimization is defined differently for
#' different solution policies. The ILP conditions are the same.
#'
#' 1. For the `lazy` policy, `installed::` packaged get 0 points, binary
#'    packages 1 point, sources packages 5 points.
#' 2. For the 'upgrade' policy, we rank all candidates for a given package
#'    according to their version numbers, and assign more points to older
#'    versions. Points are assigned by 100 and candidates with equal
#'    versions get equal points. We still prefer installed packages to
#'    binaries to source packages, so also add 0 point for already
#'    installed candidates, 1 extra points for binaries and 5 points for
#'    source packages.
#' 3. For directly specified refs, we aim to install each package exactly
#'    once. So for these we require that the variables corresponding to
#'    the same package sum up to 1.
#' 4. For non-direct refs (i.e. dependencies), we require that the
#'    variables corresponding to the same package sum up to at most one.
#'    Since every candidate has at least 1 point in the objective function
#'    of the minimization problem, non-needed dependencies will be
#'    omitted.
#' 5. For direct refs, we require that their candidates satisfy their
#'    references. What this means exactly depends on the ref types. E.g.
#'    for CRAN packages, it means that a CRAN candidate must be selected.
#'    For a standard ref, a GitHub candidate is OK as well.
#' 6. We rule out candidates for which the dependency resolution failed.
#' 7. We go over all the dependency requirements and rule out packages
#'    that do not meet them. For every package `A`, that requires
#'    package `B`, we select the `B(i, i=1..k)` candidates of `B` that
#'    satisfy `A`'s requirements and add a `A - B(1) - ... - B(k) <= 0`
#'    rule. To satisfy this rule, either we cannot install `A`, or if `A`
#'    is installed, then one of the good `B` candidates must be installed
#'    as well.
#' 8. We rule out non-installed CRAN and Bioconductor candidates for
#'    packages that have an already installed candidate with the same exact
#'    version.
#' 9. We also rule out source CRAN and Bioconductor candidates for
#'    packages that have a binary candidate with the same exact version.
#'
#' ## Explaining why the solver failed
#'
#' To be able to explain why a solution attempt failed, we also add a dummy
#' variable for each directly required package. This dummy variable has a
#' very large objective value, and it is only selected if there is no
#' way to install the directly required package.
#'
#' After a failed solution, we look the dummy variables that were selected,
#' to see which directly required package failed to solve. Then we check
#' which rule(s) ruled out the installation of these packages, and their
#' dependencies, recursively.
#'
#' ## The result
#'
#' The result of the solution is a `pkg_solution_result` object. It is a
#' named list with entries:
#'
#' * `status`: Status of the solution attempt, `"OK"` or `"FAILED"`.
#' * `data`: The selected candidates. This is very similar to a
#'   [pkg_resolution_result] object, but it has two extra columns:
#'     * `lib_status`: status of the package in the library, after the
#'        installation. Possible values: `new` (will be newly installed),
#'        `current` (up to date, not installed), `update` (will be updated),
#'        `no-update` (could update, but will not).
#'     * `old_version`: The old (current) version of the package in the
#'        library, or `NA` if the package is currently not installed.
#' * `problem`: The ILP problem. The exact representation is an
#'   implementation detail, but it does have an informative print method.
#' * `solution`: The return value of the internal solver.
#'
#' @name pkg_solution
#' @aliases pkg_solution_result
NULL

solve_dummy_obj <- 1000000000

pkgplan_solve <- function(self, private, policy) {
  "!DEBUG starting to solve `length(private$resolution$packages)` packages"
  if (is.null(private$config$library)) {
    stop("No package library specified, see 'library' in new()")
  }
  if (is.null(private$resolution)) self$resolve()
  if (private$dirty) stop("Need to resolve, remote list has changed")

  metadata <- list(solution_start = Sys.time())
  pkgs <- self$get_resolution()

  prb <- private$create_lp_problem(pkgs, policy)
  sol <- private$solve_lp_problem(prb)

  if (sol$status != 0) {
    stop("Cannot solve installation, internal lpSolve error ", sol$status)
  }

  selected <- as.logical(sol$solution[seq_len(nrow(pkgs))])
  res <- list(
    status = if (sol$objval < solve_dummy_obj - 1) "OK" else "FAILED",
    data = private$subset_resolution(selected),
    problem = prb,
    solution = sol
  )

  lib_status <- calculate_lib_status(res$data, pkgs)
  res$data <- tibble::as_tibble(cbind(res$data, lib_status))
  res$data$cache_status <-
    calculate_cache_status(res$data, private$cache)

  metadata$solution_end <- Sys.time()
  attr(res, "metadata") <- modifyList(attr(pkgs, "metadata"), metadata)
  class(res) <- unique(c("pkg_solution_result", class(res)))

  if (res$status == "FAILED") {
    res$failures <- describe_solution_error(pkgs, res)
  }

  private$solution$result <- res
  self$get_solution()
}

pkgplan_stop_for_solve_error <- function(self, private) {
  if (is.null(private$solution)) {
    stop("No solution found, need to call $solve()")
  }

  sol <- self$get_solution()

  if (sol$status != "OK") {
    msg <- paste(format(sol$failures), collapse = "\n")
    stop("Cannot install packages:\n", msg, call. = FALSE)
  }
}

pkgplan__create_lp_problem <- function(self, private, pkgs, policy) {
  pkgplan_i_create_lp_problem(pkgs, policy)
}

## Add a condition, for a subset of variables, with op and rhs
pkgplan_i_lp_add_cond <- function(
  lp, vars, op = "<=", rhs = 1, coef = rep(1, length(vars)),
  type = NA_character_, note = NULL) {

  lp$conds[[length(lp$conds)+1]] <-
    list(vars = vars, coef = coef, op = op, rhs = rhs, type = type,
         note = note)
  lp
}

## This is a separate function to make it testable without a `remotes`
## object.
##
## Variables:
## * 1:num are candidates
## * (num+1):(num+num_direct_pkgs) are the relax variables for direct refs

pkgplan_i_create_lp_problem <- function(pkgs, policy) {
  "!DEBUG creating LP problem"

  ## TODO: we could already rule out (standard) source packages if binary
  ## with the same version is present

  ## TODO: we could already rule out (standard) source and binary packages
  ## if an installed ref with the same version is present

  lp <- pkgplan_i_lp_init(pkgs, policy)
  lp <- pkgplan_i_lp_objectives(lp)
  lp <- pkgplan_i_lp_no_multiples(lp)
  lp <- pkgplan_i_lp_satisfy_direct(lp)
  lp <- pkgplan_i_lp_failures(lp)
  lp <- pkgplan_i_lp_prefer_installed(lp)
  lp <- pkgplan_i_lp_prefer_binaries(lp)
  lp <- pkgplan_i_lp_dependencies(lp)

  lp
}

pkgplan_i_lp_init <- function(pkgs, policy) {
  num_candidates <- nrow(pkgs)
  packages <- unique(pkgs$package)
  direct_packages <- unique(pkgs$package[pkgs$direct])
  indirect_packages <- setdiff(packages, direct_packages)
  num_direct <- length(direct_packages)

  structure(list(
    ## Number of package candidates
    num_candidates = num_candidates,
    ## Number of directly specified ones
    num_direct = num_direct,
    ## Total number of variables. For direct ones, we have an extra variable
    total = num_candidates + num_direct,
    ## Constraints to fill in
    conds = list(),
    pkgs = pkgs,
    policy = policy,
    ## All package names
    packages = packages,
    ## The names of the direct packages
    direct_packages = direct_packages,
    ## The names of the indirect packages
    indirect_packages = indirect_packages,
    ## Candidates (indices) that have been ruled out. E.g. resolution failed
    ruled_out = integer()
  ), class = "pkgplan_lp_problem")
}

## Coefficients of the objective function, this is very easy
## TODO: rule out incompatible platforms
## TODO: use rversion as well, for installed and binary packages

pkgplan_i_lp_objectives <- function(lp) {

  pkgs <- lp$pkgs
  policy <- lp$policy
  num_candidates <- lp$num_candidates

  if (policy == "lazy") {
    ## Simple: installed < binary < source
    lp$obj <- ifelse(pkgs$type == "installed", 0,
              ifelse(pkgs$platform == "source", 5, 1))

  } else if (policy == "upgrade") {
    ## Sort the candidates of a package according to version number
    lp$obj <- rep((num_candidates + 1) * 100, num_candidates)
    whpp <- pkgs$status == "OK" & !is.na(pkgs$version)
    pn <- unique(pkgs$package[whpp])
    for (p in pn) {
      whp <-  whpp & pkgs$package == p
      v <- pkgs$version[whp]
      r <- rank(package_version(v), ties.method = "min")
      lp$obj[whp] <- (max(r) - r + 1) * 100
      lp$obj[whp] <- lp$obj[whp] - min(lp$obj[whp])
    }
    lp$obj <- lp$obj + ifelse(pkgs$type == "installed", 1,
                       ifelse(pkgs$platform == "source", 3, 2))
    lp$obj <- lp$obj - min(lp$obj)

  } else {
    stop("Unknown version selection policy")
  }

  lp$obj <- c(lp$obj, rep(solve_dummy_obj, lp$num_direct))

  lp
}

pkgplan_i_lp_no_multiples <- function(lp) {

  ## 1. Each directly specified package exactly once.
  ##    (We also add a dummy variable to catch errors.)
  for (p in seq_along(lp$direct_packages)) {
    pkg <- lp$direct_packages[p]
    wh <- which(lp$pkgs$package == pkg)
    lp <- pkgplan_i_lp_add_cond(
      lp, c(wh, lp$num_candidates + p),
      op = "==", type = "exactly-once")
  }

  ## 2. Each non-direct package must be installed at most once
  for (p in seq_along(lp$indirect_packages)) {
    pkg <- lp$indirect_packages[p]
    wh <- which(lp$pkgs$package == pkg)
    lp <- pkgplan_i_lp_add_cond(lp, wh, op = "<=", type = "at-most-once")
  }

  lp
}

pkgplan_i_lp_satisfy_direct <-  function(lp) {

  ## 3. Direct refs must be satisfied
  satisfy <- function(wh) {
    pkgname <- lp$pkgs$package[[wh]]
    res <- lp$pkgs[wh, ]
    others <- setdiff(which(lp$pkgs$package == pkgname), wh)
    for (o in others) {
      res2 <- lp$pkgs[o, ]
      if (! isTRUE(satisfies_remote(res, res2))) {
        lp <<- pkgplan_i_lp_add_cond(
          lp, o, op = "==", rhs = 0, type = "satisfy-refs", note = wh)
      }
    }
  }
  lapply(seq_len(lp$num_candidates)[lp$pkgs$direct], satisfy)

  lp
}

pkgplan_i_lp_dependencies <- function(lp) {

  pkgs <- lp$pkgs
  num_candidates <- lp$num_candidates
  ruled_out <- lp$ruled_out
  base <- base_packages()

  ## 4. Package dependencies must be satisfied
  depconds <- function(wh) {
    if (pkgs$status[wh] != "OK") return()
    deps <- pkgs$deps[[wh]]
    deptypes <- pkgs$dep_types[[wh]]
    deps <- deps[deps$ref != "R", ]
    deps <- deps[! deps$ref %in% base, ]
    deps <- deps[tolower(deps$type) %in% tolower(deptypes), ]
    if (pkgs$platform[wh] != "source") {
      deps <- deps[tolower(deps$type) != "linkingto", ]
    }
    for (i in seq_len(nrow(deps))) {
      depref <- deps$ref[i]
      depver <- deps$version[i]
      depop  <- deps$op[i]
      deppkg <- deps$package[i]
      ## See which candidate satisfies this ref
      res <- pkgs[match(depref, pkgs$ref), ]
      cand <- which(pkgs$package == deppkg)
      good_cand <- Filter(
        x = cand,
        function(c) {
          candver <- pkgs$version[c]
          pkgs$status[[c]] != "FAILED" &&
            isTRUE(satisfies_remote(res, pkgs[c, ])) &&
            (depver == "" || version_satisfies(candver, depop, depver))
        })
      bad_cand <- setdiff(cand, good_cand)

      report <- c(
        if (length(good_cand)) {
          gc <- paste(pkgs$ref[good_cand], pkgs$version[good_cand])
          paste0("version ", paste(gc, collapse = ", "))
        },
        if (length(bad_cand)) {
          bc <- paste(pkgs$ref[bad_cand], pkgs$version[bad_cand])
          paste0("but not ", paste(bc, collapse = ", "))
        },
        if (! length(cand)) "but no candidates"
      )
      txt <- glue("{pkgs$ref[wh]} depends on {depref}: \\
                   {collapse(report, sep = ', ')}")
      note <- list(wh = wh, ref = depref, cand = cand,
                   good_cand = good_cand, txt = txt)

      lp <<- pkgplan_i_lp_add_cond(
        lp, c(wh, good_cand), "<=", rhs = 0,
        coef = c(1, rep(-1, length(good_cand))),
        type = "dependency", note = note
      )
    }
  }
  lapply(setdiff(seq_len(num_candidates), ruled_out), depconds)

  lp
}

pkgplan_i_lp_failures <- function(lp) {

  ## 5. Can't install failed resolutions
  failedconds <- function(wh) {
    if (lp$pkgs$status[wh] != "FAILED") return()
    lp <<- pkgplan_i_lp_add_cond(lp, wh, op = "==", rhs = 0,
                                 type = "ok-resolution")
    lp$ruled_out <<- c(lp$ruled_out, wh)
  }
  lapply(seq_len(lp$num_candidates), failedconds)

  lp
}

pkgplan_i_lp_prefer_installed <- function(lp) {
  pkgs <- lp$pkgs
  inst <- which(pkgs$type == "installed")
  for (i in inst) {
    ## If not a CRAN or BioC package, skip it
    repotype <- pkgs$extra[[i]]$repotype
    if (is.null(repotype) || ! repotype %in% c("cran", "bioc")) next

    ## Look for others with cran/bioc/standard type and same name & ver
    package <- pkgs$package[i]
    version <- pkgs$version[i]

    ruledout <- which(pkgs$type %in% c("cran", "bioc", "standard") &
                      pkgs$package == package & pkgs$version == version)
    lp$ruled_out <- c(lp$ruled_out, ruledout)
    for (r in ruledout) {
      lp <- pkgplan_i_lp_add_cond(lp, r, op = "==", rhs = 0,
                                  type = "prefer-installed")
    }
  }

  lp
}

pkgplan_i_lp_prefer_binaries <- function(lp) {
  pkgs <- lp$pkgs
  str <- paste0(pkgs$type, "::", pkgs$package, "@", pkgs$version)
  for (ustr in unique(str)) {
    same <- which(ustr == str)
    ## We can't do this for other packages, because version is not
    ## exclusive for those
    if (! pkgs$type[same[1]] %in% c("cran", "bioc", "standard")) next
    ## TODO: choose the right one for the current R version
    selected <- same[pkgs$platform[same] != "source"][1]
    ## No binary package, maybe there is RSPM. This is temporary,
    ## until we get proper RSPM support.
    if (is.na(selected)) {
      selected <- same[grepl("__linux__", pkgs$mirror[same])][1]
    }
    if (is.na(selected)) next
    ruledout <- setdiff(same, selected)
    lp$ruled_out <- c(lp$ruled_out, ruledout)
    for (r in ruledout) {
      lp <- pkgplan_i_lp_add_cond(lp, r, op = "==", rhs = 0,
                                  type = "prefer-binary")
    }
  }

  lp
}

#' @export

print.pkgplan_lp_problem <- function(x, ...) {
  cat(format(x, ...), sep = "\n")
}

format_cond <- function(x, cond) {
  if (cond$type == "dependency") {
    glue("{cond$note$txt}")

  } else if (cond$type == "satisfy-refs") {
    ref <- x$pkgs$ref[cond$note]
    cand <- x$pkgs$ref[cond$vars]
    glue("`{ref}` is not satisfied by `{cand}`")

  } else if (cond$type == "ok-resolution") {
    ref <- x$pkgs$ref[cond$vars]
    glue("`{ref}` resolution failed")

  } else if (cond$type == "prefer-installed") {
    ref <- x$pkgs$ref[cond$vars]
    glue("installed is preferred for `{ref}`")

  } else if (cond$type == "prefer-binary")  {
    ref <- x$pkgs$ref[cond$vars]
    glue("binary is preferred for `{ref}`")

  } else if (cond$type == "exactly-once") {
    ref <- na.omit(x$pkgs$package[cond$vars])[1]
    glue("select {ref} exactly once")

  } else if (cond$type == "at-most-once") {
    ref <- na.omit(x$pkgs$package[cond$vars])[1]
    glue("select {ref} at most once")

  } else {
    glue("Unknown constraint")
  }
}

#' @export

format.pkgplan_lp_problem <- function(x, ...) {

  result <- character()
  push <- function(...) result <<- c(result, ...)

  push("<pkgplan_lp_problem>")
  push(glue("+ refs ({x$num_candidates}):"))
  pn <- sort(x$pkgs$ref)
  push(paste0("  - ", x$pkgs$ref))

  if (length(x$conds)) {
    push(glue("+ constraints ({length(x$conds)}):"))
    conds <- drop_nulls(lapply(x$conds, format_cond, x = x))
    push(paste0("  - ", conds))
  } else {
    push(glue("+ no constraints"))
  }

  result
}

#' @importFrom lpSolve lp

pkgplan__solve_lp_problem <- function(self, private, problem) {
  res <- pkgplan_i_solve_lp_problem(problem)
  res
}

pkgplan_i_solve_lp_problem <- function(problem) {
  "!DEBUG solving LP problem"
  condmat <- matrix(0, nrow = length(problem$conds), ncol = problem$total)
  for (i in seq_along(problem$conds)) {
    cond <- problem$conds[[i]]
    condmat[i, cond$vars] <- cond$coef
  }

  dir <- vcapply(problem$conds, "[[", "op")
  rhs <- vapply(problem$conds, "[[", "rhs", FUN.VALUE = double(1))
  lp("min", problem$obj, condmat, dir, rhs, int.vec = seq_len(problem$total))
}

pkgplan_get_solution <- function(self, private) {
  if (is.null(private$solution)) {
    stop("No solution found, need to call $solve()")
  }
  private$solution$result
}

pkgplan_install_plan <- function(self, private, downloads) {
  "!DEBUG creating install plan"
  sol <- if (downloads) {
    self$get_solution_download()
  } else {
    self$get_solution()$data
  }
  if (inherits(sol, "pkgplan_solve_error")) return(sol)

  deps <- lapply(
    seq_len(nrow(sol)),
    function(i) {
      x <- sol$deps[[i]]
      if (sol$platform[[i]] != "source") {
        x <- x[tolower(x$type) != "linkingto", ]
      }
      x$package[tolower(x$type) %in% tolower(sol$dep_types[[i]])]
    })
  deps <- lapply(deps, setdiff, y = c("R", base_packages()))
  installed <- ifelse(
    sol$type == "installed",
    file.path(private$config$library, sol$package),
    NA_character_)

  res <- self$get_resolution()
  direct_packages <- res$package[res$direct]
  direct <- sol$direct |
    (sol$type == "installed" & sol$package %in% direct_packages)

  binary = sol$platform != "source"
  vignettes <- ! binary & ! sol$type %in% c("cran", "bioc", "standard") &
    private$config$`build-vignettes`

  sol$library <- private$config$library
  sol$binary <- binary
  sol$direct <- direct
  sol$dependencies <- I(deps)
  sol$installed <- installed
  sol$vignettes <- vignettes

  if (downloads) {
    tree <- ! file.exists(sol$fulltarget) & file.exists(sol$fulltarget_tree)
    sol$packaged <- !tree
    sol$file <- ifelse(tree, sol$fulltarget_tree, sol$fulltarget)
  }

  sol
}

#' @importFrom rprojroot find_package_root_file

pkgplan_export_install_plan <- function(self, private, plan_file) {
  plan_file <- plan_file %||% find_package_root_file("resolution.json")
  plan <- pkgplan_install_plan(self, private, downloads = FALSE)
  cols <- c("ref", "package", "version", "type", "direct", "binary",
            "dependencies", "vignettes", "needscompilation", "metadata",
            "library", "sources", "target")
  txt <- as_json_lite_plan(plan[, cols])
  writeLines(txt, plan_file)
}

#' @importFrom jsonlite unbox toJSON

as_json_lite_plan <- function(liteplan, pretty = TRUE, ...) {
  tolist1 <- function(x) lapply(x, function(v) lapply(as.list(v), unbox))
  liteplan$metadata <- tolist1(liteplan$metadata)
  toJSON(liteplan, pretty = pretty, ...)
}

calculate_lib_status <- function(sol, res) {
  ## Possible values at the moment:
  ## - virtual: not really a package
  ## - new: newly installed
  ## - current: up to date, not installed
  ## - update: will be updated
  ## - no-update: could update, but won't

  sres <- res[res$package %in% sol$package, c("package", "version", "type")]

  ## Check if it is not new
  lib_ver <- vcapply(sol$package, function(p) {
    c(sres$version[sres$package == p & sres$type == "installed"],
      NA_character_)[1]
  })

  ## If not new, and not "installed" type, that means update
  status <- ifelse(
    sol$type == "deps", "virtual",
      ifelse(is.na(lib_ver), "new",
        ifelse(sol$type == "installed", "current", "update")))

  # Return NA for empty sets
  mmax <- function(...) c(suppressWarnings(max(...)), NA)[1]

  ## Check for no-update
  new_version <- vcapply(seq_along(sol$package), function(i) {
    p <- sol$package[i]
    v <- if (is.na(sol$version[i])) NA_character_ else package_version(sol$version[i])
    g <- sres$package == p & !is.na(sres$version)
    mmax(sres$version[g][v < sres$version[g]])
  })
  status[status == "current" & !is.na(new_version)] <- "no-update"

  tibble::tibble(
    lib_status = status,
    old_version = lib_ver,
    new_version = new_version
  )
}

## TODO: non-CRAN packages? E.g. GH based on sha.

calculate_cache_status <- function(soldata, cache) {
  toinst <- soldata$sha256[soldata$type != "installed"]
  cached <- cache$package$find(sha256 = toinst)
  ifelse(soldata$type == "installed", NA_character_,
         ifelse(soldata$sha256 %in% cached$sha256, "hit", "miss"))
}

describe_solution_error <- function(pkgs, solution) {
  assert_that(
    ! is.null(pkgs),
    ! is.null(solution),
    solution$solution$objval >= solve_dummy_obj - 1L
  )

  num <- nrow(pkgs)
  if (!num) stop("No solution errors to describe")
  sol <- solution$solution$solution
  sol_pkg <- sol[1:num]
  sol_dum <- sol[(num+1):solution$problem$total]

  ## For each candidate, we work out if it _could_ be installed, and if
  ## not, why not. Possible cases:
  ## 1. it is is in the install plan, so it can be installed, YES
  ## 2. it failed resolution, so NO
  ## 3. it does not satisfy a direct ref for the same package, so NO
  ## 4. it conflicts with another to-be-installed candidate of the
  ##    same package, so NO
  ## 5. one of its (downstream) dependencies cannot be installed, so NO
  ## 6. otherwise YES

  FAILS <- c("failed-res", "satisfy-direct", "conflict", "dep-failed")

  state <- rep("maybe-good", num)
  note <- replicate(num, NULL)
  downstream <- replicate(num, character(), simplify = FALSE)

  state[sol_pkg == 1] <- "installed"

  ## Candidates that failed resolution
  cnd <- solution$problem$conds
  typ <- vcapply(cnd, "[[", "type")
  var <- lapply(cnd, "[[", "vars")
  fres_vars <- unlist(var[typ == "ok-resolution"])
  state[fres_vars] <- "failed-res"
  for (fv in fres_vars) {
    if (length(e <- pkgs$error[[fv]])) {
      note[[fv]] <- c(note[[fv]], conditionMessage(e))
    }
  }

  ## Candidates that conflict with a direct package
  for (w in which(typ == "satisfy-refs")) {
    sv <- var[[w]]
    down <- pkgs$ref[sv]
    up <- pkgs$ref[cnd[[w]]$note]
    state[sv] <- "satisfy-direct"
    note[[sv]] <- c(note[[sv]], glue("Conflicts {up}"))
  }

  ## Find "conflict". These are candidates that are not installed,
  ## and have an "at-most-once" constraint with another package that will
  ## be installed. So we just go over these constraints.
  for (c in cnd[typ == "at-most-once"]) {
    is_in <- sol_pkg[c$vars] != 0
    if (any(is_in)) {
      state[c$vars[!is_in]] <- "conflict"
      package <- pkgs$package[c$vars[1]]
      inst <- pkgs$ref[c$vars[is_in]]
      vv <- c$vars[!is_in]
      for (v in vv) {
        note[[v]] <- c(
          note[[v]],
          glue("{pkgs$ref[v]} conflict with {inst}, to be installed"))
      }
    }
  }

  ## Find "dep-failed". This is the trickiest. First, if there are no
  ## condidates at all
  type_dep <- typ == "dependency"
  dep_up <- viapply(cnd[type_dep], function(x) x$vars[1])
  dep_cands <- lapply(cnd[type_dep], function(x) x$vars[-1])
  no_cands <- which(! viapply(dep_cands, length) &
                    state[dep_up] == "maybe-good")
  for (x in no_cands) {
    pkg <- cnd[type_dep][[x]]$note$ref
    state[dep_up[x]] <- "dep-failed"
    note[[ dep_up[x] ]] <-
      c(note[[ dep_up[x] ]], glue("Cannot install dependency {pkg}"))
    downstream[[ dep_up[x] ]] <- c(downstream[[ dep_up[x] ]], pkg)
  }

  ## Then we start with the already known
  ## NO answers, and see if they rule out upstream packages
  new <- which(state %in% FAILS)
  while (length(new)) {
    dep_cands <- lapply(dep_cands, setdiff, new)
    which_new <- which(!viapply(dep_cands, length) & state[dep_up] == "maybe-good")
    for (x in which_new) {
      pkg <- cnd[type_dep][[x]]$note$ref
      state[ dep_up[x] ] <- "dep-failed"
      note[[ dep_up[x] ]] <- c(
        note[[ dep_up[x] ]], glue("Cannot install dependency {pkg}"))
      downstream[[ dep_up[x] ]] <- c(downstream[[ dep_up[x] ]], pkg)
    }
    new <- dep_up[which_new]
  }

  ## The rest is good
  state[state == "maybe-good"] <- "could-be"

  wh <- state %in% FAILS
  fails <- pkgs[wh, ]
  fails$failure_type <- state[wh]
  fails$failure_message <-  note[wh]
  fails$failure_down <- downstream[wh]
  class(fails) <- unique(c("pkg_solution_failures", class(fails)))

  fails
}

#' @export

format.pkg_solution_failures <- function(x, ...) {
  fails <- x
  if (!nrow(fails)) return()

  done <- rep(FALSE, nrow(x))
  res <- character()

  do <- function(i) {
    if (done[i]) return()
    done[i] <<- TRUE
    msgs <- unique(fails$failure_message[[i]])
    res <<- c(
      res, paste0(
             glue("  x Cannot install `{fails$ref[i]}`."),
             if (length(msgs)) paste0("\n    - ", msgs)
           )
    )
    down <- which(fails$ref %in% fails$failure_down[[i]])
    lapply(down, do)
  }

  direct_refs <- which(fails$direct)
  lapply(direct_refs, do)

  unique(res)
}

#' @export

`[.pkg_solution_result` <- function (x, i, j, drop = FALSE) {
  class(x) <- setdiff(class(x), "pkg_solution_result")
  NextMethod("[")
}

#' @export

format.pkg_solution_result <- function(x, ...) {
  ok <- is.null(x$failures) || nrow(x$failures) == 0
  refs <- sort(unique(x$problem$pkgs$ref[x$problem$pkgs$direct]))
  nc <- length(x$problem$conds)
  cnst <- unlist(lapply(x$problem$conds, format_cond, x = x$problem))
  solrefs <- sort(x$data$ref)
  c("<pkg_solution>",
    paste0("+ result: ", if (ok) "OK" else "FAILED"),
    "+ refs:", paste0("  - ", refs),
    if (nc == 0) "+ no constraints",
    if (nc > 0) paste0("+ constraints (", length(cnst), "):"),
    if (nc > 0) paste0("  - ", utils::head(cnst, 10)),
    if (nc > 10) "  ...",
    if (ok) c("+ solution:", paste0("  - ", solrefs)),
    if (!ok) c("x failures:", format(x$failures))
  )
}

#' @export

print.pkg_solution_result <- function(x, ...) {
  cat(format(x, ...), sep = "\n")
}
