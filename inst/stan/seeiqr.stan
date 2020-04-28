functions{
  real[] seeiqr(real t,        // time (actual time; not an increment starting at 1)
                real[] state,  // state
                real[] theta,  // parameters
                real[] x_r,    // data (real)
                int[]  x_i) {  // data (integer)
    real S     = state[1];
    real E1    = state[2];
    real E2    = state[3];
    real I     = state[4];
    real Q     = state[5];
    real R     = state[6];
    real Sd    = state[7];
    real E1d   = state[8];
    real E2d   = state[9];
    real Id    = state[10];
    real Qd    = state[11];
    real Rd    = state[12];

    real R0    = theta[1];
    real f2    = theta[2];

    real N     = x_r[1];
    real D     = x_r[2];
    real k1    = x_r[3];
    real k2    = x_r[4];
    real q     = x_r[5];
    real r     = x_r[6];
    real ur    = x_r[7];
    real f1    = x_r[8];
    real start_decline = x_r[9];
    real end_decline = x_r[10];
    real fixed_f_forecast = x_r[11];
    real last_day_obs = x_r[12];
    real day_start_fixed_f_forecast = x_r[13];

    real dydt[12];

    real f;

    f = f1;
    if (t < start_decline) {
      f = f1;
    }
    if (t >= start_decline && t < end_decline) {
      f = f2 + (end_decline - t) * (f1 - f2) / (end_decline - start_decline);
    }
    if (t >= end_decline) {
      f = f2;
    }
    if (t >= day_start_fixed_f_forecast && fixed_f_forecast != 0) {
      f = fixed_f_forecast;
    }

    dydt[1]  = -(R0/(D+1/k2)) * (I + E2 + f*(Id+E2d)) * S/N - r*S + ur*Sd;
    dydt[2]  = (R0/(D+1/k2)) * (I + E2 + f*(Id+E2d)) * S/N - k1*E1 -r*E1 + ur*E1d;
    dydt[3]  = k1*E1 - k2*E2 - r*E2 + ur*E2d;
    dydt[4]  = k2*E2 - q*I - I/D - r*I + ur*Id;
    dydt[5]  = q*I - Q/D - r*Q + ur*Qd;
    dydt[6]  = I/D + Q/D - r*R + ur*Rd;

    dydt[7]  = -(f*R0/(D+1/k2)) * (I+E2 + f*(Id+E2d)) * Sd/N + r*S - ur*Sd;
    dydt[8]  = (f*R0/(D+1/k2)) * (I+E2 + f*(Id+E2d)) * Sd/N - k1*E1d +r*E1 - ur*E1d;
    dydt[9]  = k1*E1d - k2*E2d + r*E2 - ur*E2d;
    dydt[10] = k2*E2d - q*Id - Id/D + r*I - ur*Id;
    dydt[11] = q*Id - Qd/D + r*Q - ur*Qd;
    dydt[12] = Id/D + Qd/D + r*R - ur*Rd;

    return dydt;
  }
}
data {
  int<lower=0> T;     // number of time steps
  int<lower=0> N;     // number of days
  real y0[12];        // initial state
  real t0;            // first time step
  real time[T];       // time increments
  int days[N];        // day increments
  int last_day_obs;   // last day of observed data; days after this are projections
  int daily_cases[last_day_obs]; // daily new case counts
  real x_r[13];       // data for ODEs (real numbers)
  real sampFrac[N];   // fraction of cases sampled per time step
  real delayScale;    // Weibull parameter for delay in becoming a case count
  real delayShape;    // Weibull parameter for delay in becoming a case count
  int time_day_id[N]; // last time increment associated with each day
  int time_day_id0[N];// first time increment for Weibull integration of case counts
  real R0_prior[2];   // lognormal log mean and SD for R0 prior
  real phi_prior;     // SD of normal prior on 1/sqrt(phi) [NB2(mu, phi)]
  real f2_prior[2];   // beta prior for f2
  int day_inc_sampling;   // day to switch to sampFrac2
  real sampFrac2_prior[2];   // beta prior for sampFrac2
  int<lower=0, upper=1> priors_only; // logical: include likelihood or just priors?
  int<lower=0, upper=1> est_phi; // estimate NB phi?
  int<lower=0, upper=N> n_sampFrac2; // number of sampFrac2
  int<lower=0, upper=2> obs_model; // observation model: 0 = Poisson, 1 = NB2
  real<lower=0> rw_sigma;
  int tests[N];
  real ode_control[3];
  int<lower=1> N_lik; // number of days in the likelihood
  int dat_in_lik[N_lik]; // vector of data to include in the likelihood
}
transformed data {
  int x_i[0]; // empty; needed for ODE function
}
parameters {
 real R0; // Stan ODE solver seems to be more efficient without this bounded at > 0
 real<lower=0, upper=1> f2; // strength of social distancing
 real<lower=0> phi[est_phi]; // NB2 (inverse) dispersion; `est_phi` turns on/off
 real<lower=0, upper=1> sampFrac2[n_sampFrac2];
}
transformed parameters {
  real meanDelay = delayScale * tgamma(1 + 1 / delayShape);
  real dx = time[2] - time[1]; // time increment
  real ft[T];
  real lambda_d[N];
  real sum_ft_inner;
  real eta[N]; // expected value on link scale (log)
  real k2;
  real E2;
  real E2d;
  real theta[2];
  real y_hat[T,12];
  real this_samp;
  real<lower=0> alpha[N]; // 1st shape parameter for the beta distribution
  real<lower=0> beta[N]; // 2nd shape parameter for the beta distribution
  theta[1] = R0;
  theta[2] = f2;

  y_hat = integrate_ode_bdf(seeiqr, y0, t0, time, theta, x_r, x_i, ode_control[1], ode_control[2], ode_control[3]);

  for (n in 1:N) {
    this_samp = sampFrac[n];
    if (n_sampFrac2 > 1) {
      if (n >= day_inc_sampling && n <= last_day_obs) {
        this_samp = sampFrac2[n - day_inc_sampling + 1];
      }
      if (n >= day_inc_sampling && n > last_day_obs) {
        this_samp = sampFrac2[n_sampFrac2]; // forecast with last value
      }
    }
    if (n_sampFrac2 == 1) {
      this_samp = sampFrac2[1];
    }
    for (t in 1:T) {
      ft[t] = 0; // initialize at 0 across the full 1:T
    }
    for (t in time_day_id0[n]:time_day_id[n]) { // t is an increment here
      k2 = x_r[4];
      E2 = y_hat[t,3];
      E2d = y_hat[t,9];

      ft[t] = this_samp * k2 * (E2 + E2d) *
      exp(weibull_lpdf(time[time_day_id[n]] - time[t] | delayShape, delayScale));
    }
    sum_ft_inner = 0;
    for (t in (time_day_id0[n] + 1):(time_day_id[n] - 1)) {
      sum_ft_inner += ft[t];
    }
    lambda_d[n] = 0.5 * dx *
                 (ft[time_day_id0[n]] + 2 * sum_ft_inner + ft[time_day_id[n]]);
    eta[n] = log(lambda_d[n]);
  }

  if (obs_model == 2) { // Beta-Binomial
    for (n in 1:N) {
      eta[n] = inv_logit(exp(eta[n]));
      alpha[n] = eta[n] * phi[1];
      beta[n] = (1 - eta[n]) * phi[1];
    }
  } else {
    for (n in 1:N) {
      alpha[n] = 0;
      beta[n] = 0;
    }
  }

}
model {
  // priors:
  if (est_phi && obs_model == 1) { // NB2
    // https://github.com/stan-dev/stan/wiki/Prior-Choice-Recommendations
    // D(expression(1/sqrt(x)), "x"); log(0.5 * x^-0.5/sqrt(x)^2
    1/sqrt(phi[1]) ~ normal(0, phi_prior);
    target += log(0.5) - 1.5 * log(phi[1]); // Jacobian adjustment
  }
  if (est_phi && obs_model == 2) { // Beta-Binomial
    phi[1] ~ normal(0, phi_prior);
  }
  R0 ~ lognormal(R0_prior[1], R0_prior[2]);
  f2 ~ beta(f2_prior[1], f2_prior[2]);
  if (n_sampFrac2 > 0) {
    sampFrac2[1] ~ beta(sampFrac2_prior[1], sampFrac2_prior[2]);
    if (n_sampFrac2 > 1) {
      for (n in 2:n_sampFrac2) {
        sampFrac2[n] ~ normal(sampFrac2[n-1], rw_sigma); // RW
      }
    }
  }

  // data likelihood:
  if (!priors_only) {
    if (obs_model == 0) {
      daily_cases[dat_in_lik] ~ poisson_log(eta[dat_in_lik]);
    } else if (obs_model == 1) {
      daily_cases[dat_in_lik] ~ neg_binomial_2_log(eta[dat_in_lik], phi[1]);
    } else {
      daily_cases[dat_in_lik] ~ beta_binomial(tests[dat_in_lik], alpha[dat_in_lik], beta[dat_in_lik]);
    }
  }
}
generated quantities{
  int y_rep[N]; // posterior predictive replicates
  for (n in 1:N) {
    if (obs_model == 0) {
      y_rep[n] = poisson_log_rng(eta[n]);
    } else if (obs_model == 1) {
      y_rep[n] = neg_binomial_2_log_rng(eta[n], phi[1]);
    } else {
      y_rep[n] = beta_binomial_rng(tests[n], alpha[n], beta[n]);
    }
  }
}

