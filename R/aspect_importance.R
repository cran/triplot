#' Calculates importance of variable groups (called aspects) for a selected
#' observation
#'
#' Predict aspects function takes a sample from a given dataset and modifies
#' it. Modification is made by replacing part of its aspects by values from the
#' observation. Then function is calculating the difference between the
#' prediction made on modified sample and the original sample. Finally, it
#' measures the impact of aspects on the change of prediction by using the
#' linear model or lasso.
#'
#' @param x an explainer created with the \code{DALEX::explain()} function
#' or a model to be explained.
#' @param data dataset, it will be extracted from \code{x} if it's an explainer
#' NOTE: It is best when target variable is not present in the \code{data}
#' @param predict_function predict function, it will be extracted from \code{x}
#'   if it's an explainer
#' @param label name of the model. By default it's extracted from the 'class'
#'   attribute of the model.
#' @param new_observation selected observation with columns that corresponds to
#'   variables used in the model
#' @param variable_groups list containing grouping of features into aspects
#' @param N number of observations to be sampled (with replacement) from data
#'   NOTE: Small \code{N} may cause unstable results.
#' @param n_var maximum number of non-zero coefficients after lasso fitting,
#'   if zero than linear regression is used
#' @param sample_method sampling method in \code{\link{get_sample}}
#' @param f frequency in \code{\link{get_sample}}
#' @param ... other parameters
#'
#' @return An object of the class \code{aspect_importance}. Contains data frame
#'   that describes aspects' importance.
#'
#' @importFrom stats lm
#' @importFrom stats coef
#' @importFrom stats model.matrix
#' @importFrom glmnet glmnet
#'
#' @examples
#' library("DALEX")
#'
#' model_titanic_glm <- glm(survived == 1 ~
#'                          class+gender+age+sibsp+parch+fare+embarked,
#'                          data = titanic_imputed,
#'                          family = "binomial")
#'
#' explain_titanic_glm <- explain(model_titanic_glm,
#'                                data = titanic_imputed[,-8],
#'                                y = titanic_imputed$survived == 1,
#'                                verbose = FALSE)
#'
#' aspects <- list(wealth = c("class", "fare"),
#'                 family = c("sibsp", "parch"),
#'                 personal = c("gender", "age"),
#'                 embarked = "embarked")
#'
#' predict_aspects(explain_titanic_glm,
#'                   new_observation = titanic_imputed[1,],
#'                   variable_groups = aspects)
#'
#' \donttest{
#' library("randomForest")
#' library("DALEX")
#' model_titanic_rf <-
#'  randomForest(factor(survived) ~ class + gender + age + sibsp +
#'                 parch + fare + embarked,
#'               data = titanic_imputed)
#'
#' explain_titanic_rf <- explain(model_titanic_rf,
#'                               data = titanic_imputed[,-8],
#'                               y = titanic_imputed$survived == 1,
#'                               verbose = FALSE)
#'
#' predict_aspects(explain_titanic_rf,
#'                   new_observation = titanic_imputed[1,],
#'                   variable_groups = aspects)
#'
#' }
#'
#' @export

aspect_importance <- function(x, ...)
  UseMethod("aspect_importance")

#' @rdname aspect_importance
#'
#' @export
#'


aspect_importance.explainer <- function(x, new_observation,
                                        variable_groups,
                                        N = 1000,
                                        n_var = 0,
                                        sample_method = "default",
                                        f = 2, ...) {

    # extracts model, data and predict function from the explainer ------------

  data <- x$data
  model <- x$model
  predict_function <- x$predict_function
  label <- x$label

  # check if target is in data ----------------------------------------------

  if (!is.null(x$y)) {
    target_in_data_check <- any(apply(data, 2, function(z) {
      all(as.character(z) == as.character(x$y))
    }))

    if (target_in_data_check) {
      warning("It is recommended to pass `data` without the target variable
              column")
    }
  }

  # calls target function ---------------------------------------------------

  aspect_importance.default(x = model,
                            data = data,
                            predict_function = predict_function,
                            new_observation = new_observation,
                            variable_groups = variable_groups,
                            N = N,
                            label = label,
                            n_var = n_var,
                            sample_method = sample_method,
                            f = f)
}


#' @rdname aspect_importance
#'
#' @export


aspect_importance.default <- function(x, data,
                                      predict_function = predict,
                                      label = class(x)[1],
                                      new_observation,
                                      variable_groups,
                                      N = 100,
                                      n_var = 0,
                                      sample_method = "default",
                                      f = 2,
                                      ...) {

  # look only for common variables in data and new observation --------------

  if ("data.frame" %in% class(data)) {
    common_variables <- intersect(colnames(new_observation), colnames(data))
    new_observation <- new_observation[, common_variables, drop = FALSE]
    data <- data[, common_variables, drop = FALSE]
  }

  # stop if no common variables are found -----------------------------------

  stopifnot(length(common_variables) > 0,
            length(setdiff(unlist(variable_groups),
                           colnames(new_observation))) == 0)

  # number of expected coefficients cannot be negative ----------------------

  stopifnot(n_var >= 0)

  # create empty matrix and data frames -------------------------------------

  ids <- sample.int(nrow(data), N, replace = TRUE)
  n_sample <- data[ids, ]
  n_sample_changed <- n_sample

  # sample and replace aspects  ---------------------------------------------

  new_X <- get_sample(N, length(variable_groups), sample_method, f)

  for (i in seq_len(nrow(n_sample))) {
    vars <- unlist(variable_groups[new_X[i, ] == 1])
    n_sample_changed[i, vars] <- new_observation[vars]
  }

  # calculate change in predictions -----------------------------------------

  y_changed <- predict_function(x, n_sample_changed) -
    predict_function(x, n_sample)

  # fit linear model/lasso to estimate aspects importance -------------------

  colnames(new_X) <- names(variable_groups)
  new_df <- data.frame(y_changed, new_X)

  if (n_var == 0) {
    lm_model <- lm(y_changed~., data = new_df)
    model_coef <- lm_model$coefficients
  } else {
    x_new_df <- model.matrix(y_changed ~ ., data = new_df)[, -1]
    y_new_df <- y_changed
    glmnet_model <- glmnet(x_new_df, y_new_df, alpha = 1)
    indx <- max(which(glmnet_model$df <= n_var))
    model_coef <- coef(glmnet_model)[, indx]
  }

  # prepare data frame with results ------------------------------------------

  res <- data.frame(names(model_coef), unname(model_coef))
  colnames(res) <- c("variable_groups", "importance")
  res <- res[!res$variable_groups == "(Intercept)", ]
  res <- res[order(-abs(res$importance)), ]

  for (i in seq_along(variable_groups)) {
    res$features[i] <- variable_groups[as.character(res[i, 1])]
    vars <- unlist(res$features[i])
    if (all(sapply(data[, vars], is.numeric)) & length(vars) > 1) {
      cor_matrix <- cor(data[, vars], method = "spearman")
      res$min_cor[i] <- min(abs(cor_matrix))
      res$sign[i] <- ifelse(max(cor_matrix) > 0 & min(cor_matrix) < 0,
                            "neg", "pos")
    } else {
      res$min_cor[i] <- NA
      res$sign[i] <- ""
    }
  }

  res$importance <- as.numeric(format(res$importance, digits = 4))
  class(res) <- c("aspect_importance", "data.frame")

  attr(res, "label") <- rep(label, length.out = nrow(res))

  return(res)
}

#' Function for plotting aspect_importance results
#'
#' This function plots the results of aspect_importance.
#'
#' @param x object of aspect_importance class
#' @param bar_width bar width
#' @param show_features if TRUE, labels on axis Y show aspect names, otherwise
#'   they show features names
#' @param aspects_on_axis alias for \code{show_features} held for backwards 
#'   compatibility
#' @param add_importance if TRUE, plot is annotated with values of aspects
#'   importance
#' @param digits_to_round integer indicating the number of decimal places used
#'   for rounding values of aspects importance shown on the plot
#' @param text_size size of labels annotating values of aspects importance,
#'   if applicable
#' @param ... other parameters
#'
#' @return a ggplot2 object
#'
#' @examples
#' library("DALEX")
#'
#' model_titanic_glm <- glm(survived == 1 ~
#'                          class+gender+age+sibsp+parch+fare+embarked,
#'                          data = titanic_imputed,
#'                          family = "binomial")
#'
#' explain_titanic_glm <- explain(model_titanic_glm,
#'                                data = titanic_imputed[,-8],
#'                                y = titanic_imputed$survived == 1,
#'                                verbose = FALSE)
#'
#' aspects <- list(wealth = c("class", "fare"),
#'                 family = c("sibsp", "parch"),
#'                 personal = c("gender", "age"),
#'                 embarked = "embarked")
#'
#' titanic_ai <- predict_aspects(explain_titanic_glm,
#'                   new_observation = titanic_imputed[1,],
#'                   variable_groups = aspects)
#' plot(titanic_ai)
#'
#' @import ggplot2
#' @importFrom DALEX theme_drwhy_vertical
#' @importFrom DALEX colors_discrete_drwhy
#'
#'
#' @export


plot.aspect_importance <- function(x, ..., bar_width = 10,
                                   show_features = aspects_on_axis,
                                   aspects_on_axis = TRUE,
                                   add_importance = FALSE,
                                   digits_to_round = 2,
                                   text_size = 3) {

  stopifnot("aspect_importance" %in% class(x))
  importance <- a_sign <- variable_groups <- features <- hjust <- NULL

# order bars --------------------------------------------------------------

  x$variable_groups <- reorder(x$variable_groups, abs(x[, 2]), na.rm = TRUE)
  features_ordered <- sapply(x$features, paste0, collapse = ", ")

# bind aspect_importance data frames --------------------------------------

  dfl <- c(list(x), list(...))
  labels_list <- unlist(lapply(dfl, attr, "label"))
  x <- do.call(rbind, dfl)
  x <- cbind(x, labels_list)

# reformat features list --------------------------------------------------

  if (!show_features) {
    x$features <- sapply(x$features, paste0, collapse = ", ")
  }

# prep data  --------------------------------------------------------------

  colnames(x)[ncol(x)] <- "label"
  x$a_sign <- ifelse(x$importance > 0, "positive", "negative")
  x$hjust <- ifelse(x$importance > 0, 1.1, -0.1)

  if (all(x$importance > 0)) {
    vcol <- colors_discrete_drwhy(3)[c(3)]
  } else {
    vcol <- colors_discrete_drwhy(3)[c(2,3)]
  }

# prep plot ---------------------------------------------------------------

  if (show_features) {
    p <- ggplot(x, aes(variable_groups, ymin = 0, ymax = importance,
                       color = a_sign)) +
      geom_linerange(size = bar_width) +
      facet_wrap(~label, scales = "free_y", nrow = 1)
  } else {
    x$features <- factor(x$features, levels = rev(features_ordered))
    p <- ggplot(x, aes(features, ymin = 0, ymax = importance, color = a_sign)) +
      geom_linerange(size = bar_width) +
      facet_wrap(~label, scales = "free_y", nrow = 1)
  }

  if (add_importance & show_features) {
    p <- p + geom_text(aes(x = variable_groups, y = importance,
                           label = round(importance, digits_to_round),
                           hjust = hjust), vjust = 0.5, color = "#371ea3",
                       size = text_size)
  } else if (add_importance & !show_features) {
    p <- p + geom_text(aes(x = features, y = importance,
                           label = round(importance, digits_to_round),
                           hjust = hjust),
                       vjust = 0.5, color = "#371ea3", size = text_size)
  }

  # plot it -----------------------------------------------------------------
  p + coord_flip() +
    ylab("Aspects importance") + xlab("") + theme_drwhy_vertical() +
    theme(legend.position = "none",
          panel.grid.major = element_blank(),
          panel.grid.minor = element_blank()) +
    scale_color_manual(values = vcol)

}


# print aspect_importance object ------------------------------------------

#' Function for printing aspect_importance results
#'
#' This function prints the results of aspect_importance.
#'
#' @param x object of aspect_importance class
#' @param show_features show list of features for every aspect
#' @param show_corr show if all features in aspect are pairwise positively
#'   correlated (for numeric features only)
#' @param ... other parameters
#'
#' @examples
#' library("DALEX")
#'
#' model_titanic_glm <- glm(survived == 1 ~
#'                          class+gender+age+sibsp+parch+fare+embarked,
#'                          data = titanic_imputed,
#'                          family = "binomial")
#'
#' explain_titanic_glm <- explain(model_titanic_glm,
#'                                data = titanic_imputed[,-8],
#'                                y = titanic_imputed$survived == 1,
#'                                verbose = FALSE)
#'
#' aspects <- list(wealth = c("class", "fare"),
#'                 family = c("sibsp", "parch"),
#'                 personal = c("gender", "age"),
#'                 embarked = "embarked")
#'
#' titanic_ai <- predict_aspects(explain_titanic_glm,
#'                   new_observation = titanic_imputed[1,],
#'                   variable_groups = aspects)
#' print(titanic_ai)
#'
#' @export

print.aspect_importance <- function(x, show_features = FALSE, show_corr = FALSE,
                                    ...) {

  stopifnot("aspect_importance" %in% class(x))

  if (show_features) {
    res <- x[, c("variable_groups", "importance", "features")]
  } else {
    res <- x[, c("variable_groups", "importance")]
  }

  if (show_corr) {
    res <- cbind(res, x[, c("min_cor", "sign")])
  }

  print.data.frame(res)

}


# list of aliases for aspect_importance() ---------------------------------


#' @export
#' @rdname aspect_importance

lime <- aspect_importance

#' @export
#' @rdname aspect_importance

predict_aspects <- aspect_importance


#' Function for getting binary matrix
#'
#' Function creates binary matrix, to be used in aspect_importance method. It
#' starts with a zero matrix. Then it replaces some zeros with ones. If
#' \code{sample_method = "default"} it randomly replaces one or two zeros per
#' row. If \code{sample_method = "binom"} it replaces random number of zeros
#' per row - average number of replaced zeros can be controlled by parameter
#' \code{sample_method = "f"}. Function doesn't allow the returned matrix to
#' have rows with only zeros.
#'
#' @param n number of rows
#' @param p number of columns
#' @param sample_method sampling method
#' @param f frequency for binomial sampling
#'
#' @return a binary matrix
#'
#' @importFrom stats rbinom
#'
#' @examples
#'  get_sample(100,6,"binom",3)
#'
#' @export
#'
#' @rdname get_sample

get_sample <- function(n, p, sample_method = c("default", "binom"), f = 2) {

  sample_method <- match.arg(sample_method)
  stopifnot(n > 0, p > 0, f > 0)

  x <- matrix(0, n, p)

  if (sample_method == "binom") {
    for (i in 1:n) {
      n_of_changes <- pmax(rbinom(1, p, f / p), 1)
      x[i, unique(sample(1:p, n_of_changes, replace = TRUE))] <- 1
    }
  } else {
    for (i in 1:n) {
      x[i, unique(sample(1:p, 2, replace = TRUE))] <- 1
    }
  }

  return(x)
}
