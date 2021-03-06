backend_clustermq <- function(config) {
  assert_pkg("clustermq", version = "0.8.5")
  config$queue <- new_priority_queue(
    config = config,
    jobs = config$jobs_preprocess
  )
  cmq_local_master(config)
  if (config$queue$empty()) {
    return()
  }
  config$workers <- clustermq::workers(
    n_jobs = config$jobs,
    template = config$template
  )
  log_msg("setting common data", config = config)
  cmq_set_common_data(config)
  config$counter <- new.env(parent = emptyenv())
  config$counter$remaining <- config$queue$size()
  cmq_master(config)
}

cmq_local_master <- function(config) {
  while (!config$queue$empty()) {
    target <- config$queue$peek0()
    if (identical(config$layout[[target]]$hpc, FALSE)) {
      config$queue$pop0()
      cmq_local_build(target, config)
      next
    }
    meta <- drake_meta_(target = target, config = config)
    if (should_build_target(target, meta, config)) {
      return()
    }
    log_msg("skip", target, config = config)
    config$queue$pop0()
    cmq_conclude_target(target, config)
  }
}

cmq_set_common_data <- function(config) {
  export <- list()
  if (identical(config$envir, globalenv())) {
    export <- as.list(config$envir, all.names = TRUE) # nocov
  }
  export$config <- cmq_config(config)
  config$workers$set_common_data(
    export = export,
    fun = identity,
    const = list(),
    rettype = list(),
    common_seed = config$seed,
    token = "set_common_data_token"
  )
}

cmq_master <- function(config) {
  on.exit(config$workers$finalize())
  log_msg("begin scheduling targets", config = config)
  while (config$counter$remaining > 0) {
    msg <- config$workers$receive_data()
    cmq_conclude_build(msg = msg, config = config)
    if (!identical(msg$token, "set_common_data_token")) {
      log_msg("sending common data", config = config)
      config$workers$send_common_data()
    } else if (!config$queue$empty()) {
      cmq_next_target(config)
    } else {
      config$workers$send_shutdown_worker()
    }
  }
  if (config$workers$cleanup()) {
    on.exit()
  }
}

cmq_next_target <- function(config) {
  target <- config$queue$pop0()
  # Longer tests will catch this:
  if (!length(target)) {
    config$workers$send_wait() # nocov
    return() # nocov
  }
  if (identical(config$layout[[target]]$hpc, FALSE)) {
    config$workers$send_wait()
    cmq_local_build(target, config)
  } else {
    cmq_send_target(target, config)
  }
}

cmq_send_target <- function(target, config) {
  meta <- drake_meta_(target = target, config = config)
  if (!should_build_target(target, meta, config)) {
    log_msg("skip", target, config = config)
    cmq_conclude_target(target = target, config = config)
    config$workers$send_wait()
    return()
  }
  announce_build(target = target, meta = meta, config = config)
  if (identical(config$caching, "master")) {
    manage_memory(targets = target, config = config, jobs = 1)
    deps <- cmq_deps_list(target = target, config = config)
  } else {
    deps <- NULL
  }
  layout <- config$layout[[target]]
  config$workers$send_call(
    expr = drake::cmq_build(
      target = target,
      meta = meta,
      deps = deps,
      layout = layout,
      config = config
    ),
    env = list(target = target, meta = meta, deps = deps, layout = layout)
  )
}

cmq_config <- function(config) {
  discard <- c(
    "imports",
    "layout",
    "plan",
    "targets",
    "trigger"
  )
  for (x in discard) {
    config[[x]] <- NULL
  }
  config$cache$flush_cache()
  config
}

cmq_deps_list <- function(target, config) {
  deps <- config$layout[[target]]$deps_build$memory
  out <- lapply(
    X = deps,
    FUN = function(name) {
      config$eval[[name]]
    }
  )
  names(out) <- deps
  out
}

cmq_local_build <- function(target, config) {
  log_msg("build", target, "locally", config = config)
  loop_build(target, config, downstream = NULL)
  cmq_conclude_target(target = target, config = config)
}

#' @title Build a target using the clustermq backend
#' @description For internal use only
#' @export
#' @keywords internal
#' @inheritParams drake_build
#' @param target Target name.
#' @param meta List of metadata.
#' @param deps Named list of target dependencies.
#' @param layout Internal, part of the full `config$layout`.
#' @param config A [drake_config()] list.
cmq_build <- function(target, meta, deps, layout, config) {
  log_msg("build", target, "on an hpc worker", config = config)
  config$layout <- list()
  config$layout[[target]] <- layout
  do_prework(config = config, verbose_packages = FALSE)
  if (identical(config$caching, "master")) {
    for (dep in names(deps)) {
      config$eval[[dep]] <- deps[[dep]]
    }
  } else {
    manage_memory(targets = target, config = config, jobs = 1)
  }
  build <- build_target(target = target, meta = meta, config = config)
  if (identical(config$caching, "master")) {
    build$checksum <- mc_get_outfile_checksum(target, config)
    return(build)
  }
  conclude_build(build = build, config = config)
  list(target = target, checksum = mc_get_checksum(target, config))
}

cmq_conclude_build <- function(msg, config) {
  build <- msg$result
  if (is.null(build)) {
    return()
  }
  if (inherits(build, "try-error")) {
    stop(attr(build, "condition")$message, call. = FALSE) # nocov
  }
  cmq_conclude_target(target = build$target, config = config)
  if (identical(config$caching, "worker")) {
    mc_wait_checksum(
      target = build$target,
      checksum = build$checksum,
      config = config
    )
    return()
  }
  mc_wait_outfile_checksum(
    target = build$target,
    checksum = build$checksum,
    config = config
  )
  conclude_build(build = build, config = config)
}

cmq_conclude_target <- function(target, config) {
  decrease_revdep_keys(queue = config$queue, target = target, config = config)
  config$counter$remaining <- config$counter$remaining - 1
}
