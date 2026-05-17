# Linear regression demo. Run with: Rscript main.R

set.seed(42)

# Simulate y = 2*x + 3 + noise
n <- 5000
x <- runif(n, min = 0, max = 100)
noise <- rnorm(n, mean = 0, sd = 1.5)
y <- 2 * x + 3 + noise

# Fit a simple linear model
model <- lm(y ~ x)
coefs <- coef(model)

cat(sprintf("intercept: %.3f (true: 3)\n", coefs[["(Intercept)"]]))
cat(sprintf("slope:     %.3f (true: 2)\n", coefs[["x"]]))
cat(sprintf("R^2:       %.3f\n", summary(model)$r.squared))

# Helper: classify residuals by magnitude
classify <- function(residuals) {
  sapply(residuals, function(r) {
    if (abs(r) < 1) "small"
    else if (abs(r) < 2) "medium"
    else "large"
  })
}

bucket <- classify(residuals(model))
cat("\nresidual buckets:\n")
print(table(bucket))
