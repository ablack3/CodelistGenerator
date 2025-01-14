#' Summarise code use in patient-level data
#'
#' @param x Vector of concept IDs
#' @param cdm cdm_reference via CDMConnector::cdm_from_con()
#' @param countBy Either "record" for record-level counts or "person" for
#' person-level counts
#' @param byConcept TRUE or FALSE. If TRUE code use will be summarised by
#'
#' @param byYear TRUE or FALSE. If TRUE code use will be summarised by year.
#' @param bySex TRUE or FALSE. If TRUE code use will be summarised by sex.
#' @param ageGroup If not NULL, a list of ageGroup vectors of length two.
#' @param minCellCount The minimum number of counts to reported, below which
#' results will be suppressed. If 0, all results will be reported.
#'
#' @return A tibble with results overall and, if specified, by strata
#' @export
#'
#' @examples
summariseCodeUse <- function(x,
                             cdm,
                             countBy = c("record", "person"),
                             byConcept = TRUE,
                             byYear = TRUE,
                             bySex = TRUE,
                             ageGroup = list(c(0,17),
                                             c(18,65),
                                             c(66, 120)),
                             minCellCount = 5){


  errorMessage <- checkmate::makeAssertCollection()
  checkDbType(cdm = cdm, type = "cdm_reference", messageStore = errorMessage)
  checkmate::assertTRUE(all(countBy %in% c("record", "person")))
  checkmate::assertIntegerish(x, add = errorMessage)
  checkmate::assert_logical(byConcept, add = errorMessage)
  checkmate::assert_logical(byYear, add = errorMessage)
  checkmate::assert_logical(bySex, add = errorMessage)
  checkmate::assert_numeric(minCellCount, len = 1,
                            add = errorMessage)
  checkmate::reportAssertions(collection = errorMessage)

  checkAgeGroup(ageGroup = ageGroup)


  codes <- dplyr::tibble(concept_id = x) %>%
    dplyr::left_join(cdm[["concept"]] %>%
                       dplyr::select("concept_id", "domain_id"),
                     by = "concept_id",
                     copy = TRUE)

  codes <- codes %>%
    addDomainInfo(cdm = cdm)

  records <- getRelevantRecords(codes = codes,
                                cdm = cdm)

  if(!is.null(records)) {
  records <- records %>%
    dplyr::left_join(cdm[["concept"]] %>%
                       dplyr::select("concept_id", "concept_name"),
                     by = "concept_id")

  if(bySex == TRUE | !is.null(ageGroup)){
    records <- records %>%
      PatientProfiles::addDemographics(cdm = cdm,
                                       age = !is.null(ageGroup),
                                       ageGroup = ageGroup,
                                       sex = bySex,
                                       priorHistory = FALSE,
                                       futureObservation =  FALSE,
                                       indexDate = "date")
  }

  byAgeGroup <- !is.null(ageGroup)
  codeCounts <- getSummaryCounts(records = records,
                                 cdm = cdm,
                                 countBy = countBy,
                                 byConcept = byConcept,
                                 byYear = byYear,
                                 bySex = bySex,
                                 byAgeGroup = byAgeGroup)

  codeCounts <-  codeCounts %>%
    dplyr::mutate(estimate_suppressed = dplyr::if_else(
      .data$estimate < .env$minCellCount, "TRUE", "FALSE")) %>%
    dplyr::mutate(estimate = dplyr::if_else(
      .data$estimate_suppressed == "TRUE",
      NA, .data$estimate))

  if(!"record" %in% countBy){
    codeCounts <- codeCounts %>%
      dplyr::mutate(concept_name= NA,
                    concept_id =NA)
  }

  codeCounts <- codeCounts %>%
    dplyr::mutate(group_level = dplyr::if_else(.data$group_name == "By concept",
                                        paste0(.data$concept_name, " (",
                                               .data$concept_id, ")"),
                                        "Overall")) %>%
    dplyr::mutate(variable_type = "Numeric",
                  variable_level = "Overall",
                  estimate_type = "Count") %>%
    dplyr::select(dplyr::all_of(c("group_name", "group_level",
                                "strata_name", "strata_level",
                                "variable_name", "variable_level",
                                "variable_type",
                                "estimate_type",
                                "estimate",
                                "estimate_suppressed")))

} else {
  codeCounts <- dplyr::tibble()
  cli::cli_inform(
    c(
      "i" = "No records found in the cdm for the concepts provided."
    ))
}

return(codeCounts)
}

addDomainInfo <- function(codes,
                          cdm) {

  codes <- codes %>%
    dplyr::mutate(domain_id = tolower(.data$domain_id)) %>%
    dplyr::mutate(table_name =
                    dplyr::case_when(
               stringr::str_detect(domain_id,"condition") ~ "condition_occurrence",
               stringr::str_detect(domain_id,"drug") ~ "drug_exposure",
               stringr::str_detect(domain_id,"observation") ~ "observation",
               stringr::str_detect(domain_id,"measurement") ~ "measurement",
               stringr::str_detect(domain_id,"visit") ~ "visit_occurrence",
               stringr::str_detect(domain_id,"procedure") ~ "procedure_occurrence"
             )
    ) %>%
    dplyr::mutate(concept_id_name =
                    dplyr::case_when(
               stringr::str_detect(domain_id,"condition") ~ "condition_concept_id",
               stringr::str_detect(domain_id,"drug") ~ "drug_concept_id",
               stringr::str_detect(domain_id,"observation") ~ "observation_concept_id",
               stringr::str_detect(domain_id,"measurement") ~ "measurement_concept_id",
               stringr::str_detect(domain_id,"visit") ~ "visit_concept_id",
               stringr::str_detect(domain_id,"procedure") ~ "procedure_concept_id"
             )
    ) %>%
    dplyr::mutate(date_name =
                    dplyr::case_when(
               stringr::str_detect(domain_id,"condition") ~ "condition_start_date",
               stringr::str_detect(domain_id,"drug") ~ "drug_exposure_start_date",
               stringr::str_detect(domain_id,"observation") ~ "observation_date",
               stringr::str_detect(domain_id,"measurement") ~ "measurement_date",
               stringr::str_detect(domain_id,"visit") ~ "visit_start_date",
               stringr::str_detect(domain_id,"procedure") ~ "procedure_date"
             )
    )

  return(codes)

}


getRelevantRecords <- function(codes,
                               cdm){

  tableName <- purrr::discard(unique(codes$table_name), is.na)
  conceptIdName <- purrr::discard(unique(codes$concept_id_name), is.na)
  dateName <- purrr::discard(unique(codes$date_name), is.na)

  # filter to relevant records
if(length(tableName)>0){
  codeRecords <- cdm[[tableName[[1]]]] %>%
    dplyr::mutate(date = !!dplyr::sym(dateName[[1]])) %>%
    dplyr::mutate(year = lubridate::year(date)) %>%
    dplyr::select(dplyr::all_of(c("person_id", conceptIdName[[1]],
                           "date", "year"))) %>%
    dplyr::rename("concept_id" = .env$conceptIdName[[1]]) %>%
    dplyr::inner_join(codes %>%
                        dplyr::filter(.data$table_name == tableName[[1]]) %>%
                        dplyr::select("concept_id"),
                      by = "concept_id",
                      copy = TRUE) %>%
    CDMConnector::compute_query()
} else {
  codeRecords <- NULL
}

  # get for any additional domains and union
  if(length(tableName) > 1) {
    for(i in 1:(length(tableName)-1)) {
      workingRecords <-  cdm[[tableName[[i+1]]]] %>%
        dplyr::mutate(date = !!dplyr::sym(dateName[[i+1]])) %>%
        dplyr::mutate(year = lubridate::year(date)) %>%
        dplyr::select(dplyr::all_of(c("person_id", conceptIdName[[i+1]],
                                      "date", "year"))) %>%
        dplyr::rename("concept_id" = .env$conceptIdName[[i+1]]) %>%
        dplyr::inner_join(codes %>%
                            dplyr::filter(.data$table_name == tableName[[i+1]]) %>%
                            dplyr::select("concept_id"),
                          by = "concept_id",
                          copy = TRUE)
      codeRecords <- codeRecords %>%
        dplyr::union_all(workingRecords) %>%
        CDMConnector::compute_query()
    }
  }

  return(codeRecords)

}


getSummaryCounts <- function(records,
                             cdm,
                             countBy,
                             byConcept,
                             byYear,
                             bySex,
                             byAgeGroup){

if("record" %in% countBy){
recordSummary <- records %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "Codelist") %>%
    dplyr::collect()
if(isTRUE(byConcept)) {
  recordSummary <- dplyr::bind_rows(recordSummary,
                   records %>%
    dplyr::group_by(.data$concept_id, .data$concept_name) %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "By concept") %>%
    dplyr::collect())
}
recordSummary <- recordSummary %>%
  dplyr::mutate(
    strata_name = "Overall",
    strata_level = "Overall",
    variable_name = "Record count")
} else {
  recordSummary <- dplyr::tibble()
}

if("person" %in% countBy){
personSummary <- records %>%
    dplyr::select("person_id") %>%
    dplyr::distinct() %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "Codelist") %>%
    dplyr::collect()

if(isTRUE(byConcept)) {
personSummary <- dplyr::bind_rows(personSummary,
  records %>%
    dplyr::select("person_id", "concept_id", "concept_name") %>%
    dplyr::distinct() %>%
    dplyr::group_by(.data$concept_id, .data$concept_name) %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "By concept") %>%
    dplyr::collect())
  }
personSummary <- personSummary %>%
  dplyr::mutate(
    strata_name = "Overall",
    strata_level = "Overall",
    variable_name = "Person count")
} else {
  personSummary <- dplyr::tibble()
}


if("record" %in% countBy & byYear == TRUE){
  recordSummary <- dplyr::bind_rows(recordSummary,
                                    getGroupedRecordCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "year",
                                                          groupName = "Year"))
}
  if("person" %in% countBy & byYear == TRUE){
  personSummary <- dplyr::bind_rows(personSummary,
                                    getGroupedPersonCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "year",
                                                          groupName = "Year"))

  }

if("record" %in% countBy & bySex == TRUE){
  recordSummary <- dplyr::bind_rows(recordSummary,
                                    getGroupedRecordCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "sex",
                                                          groupName = "Sex"))
}

if("person" %in% countBy & bySex == TRUE){
  personSummary <- dplyr::bind_rows(personSummary,
                                    getGroupedPersonCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "sex",
                                                          groupName = "Sex"))
}


  if("record" %in% countBy & byAgeGroup == TRUE){
  recordSummary <- dplyr::bind_rows(recordSummary,
                                    getGroupedRecordCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "age_group",
                                                          groupName = "Age group"))
  }

  if("person" %in% countBy & byAgeGroup == TRUE){
  personSummary <- dplyr::bind_rows(personSummary,
                                    getGroupedPersonCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = "age_group",
                                                          groupName = "Age group"))
}

if("record" %in% countBy && byAgeGroup == TRUE && bySex == TRUE){
  recordSummary <- dplyr::bind_rows(recordSummary,
                                    getGroupedRecordCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = c("age_group",
                                                                      "sex"),
                                                          groupName = "Age group and sex"))
}

  if("person" %in% countBy && byAgeGroup == TRUE && bySex == TRUE){
  personSummary <- dplyr::bind_rows(personSummary,
                                    getGroupedPersonCount(records = records,
                                                          cdm = cdm,
                                                          groupBy = c("age_group",
                                                                      "sex"),
                                                          groupName = "Age group and sex"))
}



summary <- dplyr::bind_rows(recordSummary, personSummary)

 return(summary)

}


getGroupedRecordCount <- function(records,
                                  cdm,
                                  groupBy,
                                  groupName){

groupedCounts <- dplyr::bind_rows(
   records %>%
     dplyr::group_by(dplyr::pick(.env$groupBy)) %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "Codelist") %>%
    dplyr::collect(),
  records %>%
    dplyr::group_by(dplyr::pick(.env$groupBy,
                                "concept_id", "concept_name")) %>%
    dplyr::tally(name = "estimate") %>%
    dplyr::mutate(estimate = as.integer(.data$estimate),
                  group_name = "By concept"
                  ) %>%
    dplyr::collect())  %>%
  tidyr::unite("groupvar",
               c(dplyr::all_of(.env$groupBy)),
               remove = FALSE, sep = " and ") %>%
  dplyr::mutate(strata_name = groupName,
                strata_level = as.character(.data$groupvar),
                variable_name = "Record count") %>%
  dplyr::select(!c(groupBy, "groupvar"))

return(groupedCounts)

}

getGroupedPersonCount <- function(records,
                                  cdm,
                                  groupBy,
                                  groupName){

  groupedCounts <- dplyr::bind_rows(
    records %>%
      dplyr::select(dplyr::all_of(c("person_id", .env$groupBy))) %>%
      dplyr::distinct() %>%
      dplyr::group_by(dplyr::pick(.env$groupBy)) %>%
      dplyr::tally(name = "estimate") %>%
      dplyr::mutate(estimate = as.integer(.data$estimate),
                    group_name = "Codelist") %>%
      dplyr::collect(),
    records %>%
      dplyr::select(dplyr::all_of(c("person_id",
                                    "concept_id", "concept_name",
                                    .env$groupBy))) %>%
      dplyr::distinct() %>%
      dplyr::group_by(dplyr::pick(.env$groupBy,
                                  "concept_id", "concept_name")) %>%
      dplyr::tally(name = "estimate") %>%
      dplyr::mutate(estimate = as.integer(.data$estimate),
                    group_name = "By concept"
      ) %>%
      dplyr::collect()) %>%
    tidyr::unite("groupvar",
                 c(tidyselect::all_of(.env$groupBy)),
                 remove = FALSE, sep = " and ") %>%
    dplyr::mutate(strata_name = groupName,
                  strata_level = as.character(.data$groupvar),
                  variable_name = "Person count") %>%
    dplyr::select(!c(.env$groupBy, "groupvar"))

  return(groupedCounts)

}



checkCategory <- function(category, overlap = FALSE) {
  checkmate::assertList(
    category,
    types = "integerish", any.missing = FALSE, unique = TRUE,
    min.len = 1
  )

  if (is.null(names(category))) {
    names(category) <- rep("", length(category))
  }

  # check length
  category <- lapply(category, function(x) {
    if (length(x) == 1) {
      x <- c(x, x)
    } else if (length(x) > 2) {
      cli::cli_abort(
        paste0(
          "Categories should be formed by a lower bound and an upper bound, ",
          "no more than two elements should be provided."
        ),
        call. = FALSE
      )
    }
    return(x)
  })

  # check lower bound is smaller than upper bound
  checkLower <- unlist(lapply(category, function(x) {
    x[1] <= x[2]
  }))
  if (!(all(checkLower))) {
    cli::cli_abort("Lower bound should be equal or smaller than upper bound")
  }

  # built tibble
  result <- lapply(category, function(x) {
    dplyr::tibble(lower_bound = x[1], upper_bound = x[2])
  }) %>%
    dplyr::bind_rows() %>%
    dplyr::mutate(category_label = names(.env$category)) %>%
    dplyr::mutate(category_label = dplyr::if_else(
      .data$category_label == "",
      paste0(.data$lower_bound, " to ", .data$upper_bound),
      .data$category_label
    )) %>%
    dplyr::arrange(.data$lower_bound)

  # check overlap
  if(!overlap) {
    if (nrow(result) > 1) {
      lower <- result$lower_bound[2:nrow(result)]
      upper <- result$upper_bound[1:(nrow(result) - 1)]
      if (!all(lower > upper)) {
        cli::cli_abort("There can not be overlap between categories")
      }
    }
  }

  return(result)
}

checkAgeGroup <- function(ageGroup, overlap = FALSE) {
  checkmate::assertList(ageGroup, min.len = 1, null.ok = TRUE)
  if (!is.null(ageGroup)) {
    if (is.numeric(ageGroup[[1]])) {
      ageGroup <- list("age_group" = ageGroup)
    }
    for (k in seq_along(ageGroup)) {
      invisible(checkCategory(ageGroup[[k]], overlap))
    }
    if (is.null(names(ageGroup))) {
      names(ageGroup) <- paste0("age_group_", 1:length(ageGroup))
    }
    if ("" %in% names(ageGroup)) {
      id <- which(names(ageGroup) == "")
      names(ageGroup)[id] <- paste0("age_group_", id)
    }
  }
  return(ageGroup)
}
