## intermahpr - R package backend for the intermahp shiny app
## Copyright (C) 2018 Canadian Institute for Substance Use Research

#### Population Specific Data Carpentry ----------------------------------------

#' Prepare Population Data
#' @export
preparePC <- function(.data, ...) {
  message("Preparing prevalence and consumption input... ", appendLF = FALSE)
  .data %<>%
    clean(getExpectedVars("pc")) %>%
    setPopnConstants(...) %>%
    computePopnMetrics()

  message("Done")
  .data
}

#' Return PC dataset for viewing in wide format
#' @export
renderPCWide <- function(.data) {
  .data %>%
    select(getExpectedVars("pc_display")) %>%
    rename("gamma_normalizer" = "nc")
}

#### Population metric alterations ---------------------------------------------

#' Set Population Constants
#'@param bb binge barrier
#'@param lb lower bound of consumption
#'@param ub upper bound of consumption
#'
setPopnConstants <- function(
  .data, bb = list("Female" = 53.8, "Male" = 67.25), lb = 0.03, ub = 250
) {
  mutate(.data, lb = lb, bb = map_dbl(gender, ~`[[`(bb, .x)), ub = ub)
}

#' Compute Population Metrics
computePopnMetrics <- function(.data) {
  ## 'Magic' numbers
  yearly_to_daily_conv = 0.002739726
  litres_to_millilitres_conv = 1000
  millilitres_to_grams_ethanol_conv = 0.7893

  .data %>%
    group_by(region, year) %>%
    mutate(
      pcc_g_day =
        pcc_litres_year *
        litres_to_millilitres_conv *
        millilitres_to_grams_ethanol_conv *
        yearly_to_daily_conv *
        correction_factor,
      drinkers = population * p_cd
    ) %>% mutate(
      ## Deprecated along with the pcc_among_drinkers variable
      ## alcohol consumption over all age groups
      #   pcad = pcc_g_day * sum(population) / sum(drinkers)
      # ) %>% mutate(
      ## mean consumption per age group
      pcc_among_popn = pcc_g_day * sum(population) * relative_consumption /
        sum(relative_consumption * population)
      ## WHO definition gives Ac among drinkers, intermahp defintions want
      ## AC among population
      ## The following is deprecated, as is the pcad variable.
      # pcc_among_drinkers = relative_consumption * pcad * sum(drinkers) /
      # sum(relative_consumption*drinkers)
    ) %>%
    ungroup %>%
    mutate(
      gamma_shape = 1/gamma_constant/gamma_constant,
      gamma_scale = gamma_constant*gamma_constant*pcc_among_popn
    ) %>%
    mutate(
      glb = pgamma(q = lb, shape = gamma_shape, scale = gamma_scale),
      gbb = pgamma(q = bb, shape = gamma_shape, scale = gamma_scale),
      gub = pgamma(q = ub, shape = gamma_shape, scale = gamma_scale)
    ) %>%
    mutate(
      ## For low consumption regions, integral may converge when full area of
      ## the gamma distribution is below binge level
      ub = ifelse(gbb == 1, bb, ub)
    ) %>%
    mutate(
      nc = gub - glb
    ) %>%
    mutate(
      df = p_cd / nc
    ) %>%
    mutate(
      n_gamma = pmap(
        list(shape = gamma_shape, scale = gamma_scale, factor = df),
        makeNormalizedGamma
      ),
      p_bat = df * (gub - gbb)
    ) %>%
    mutate(
      ## p_bat is "bingers above threshold", i.e. daily bingers on average.
      ## If p_bat >= p_bd, we must fix this by deflating the tail of the gamma
      ## distribution above the binge barrier and setting p_bat equal to p_bd.
      p_bat_error_correction = ifelse(p_bat > p_bd, p_bd / p_bat, 1),
      p_bat = ifelse(p_bat > p_bd, p_bd, p_bat)
    ) %>%
    mutate(
      n_pgamma = pmap(list(f = n_gamma, lb = lb), makeIntegrator)
    ) %>%
    mutate(
      ## proportion of nonbingers and bingers "below threshold", i.e.
      ## that are not daily bingers on average.
      non_bingers = (p_cd - p_bd)  / (p_cd - p_bat),
      bingers = (p_bd - p_bat) / (p_cd - p_bat)
    )
}

#' Rescale Population Data
#'
#'@param .data cleaned population data with constants set
#'@param scale a percentage of the current consumption expected in the
#'scenario under study
#'
#'@return Rescaled consumption data (just pc_vars)
#'
rescale <- function(.data, scale = 1) {
  base <- computePopnMetrics(.data)

  .data %>%
    mutate(pcc_litres_year = scale * pcc_litres_year) %>%
    computePopnMetrics() %>%
    mutate(
      ## We're ensuring the ratio of bingers above threshold satys the same,
      ## so if either p_bat is 0 we just hold p_bd constant.
      p_bd = ifelse(
        base$p_bat > 0 & p_bat > 0,
        p_bd * p_bat / base$p_bat,
        p_bd)
      ) %>%
    select(getExpectedVars("pc", "constants"))
}
