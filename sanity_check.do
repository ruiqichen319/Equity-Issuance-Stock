//----------------------------------------------------------------------------//
/*
Sanity check: compare our reconstructed model-implied ICS against the
author's original series over the overlap window.

Note: standardization in main_data_update_v2.do is over 1964-2026, while the
author's standardization window was 1964 - last_old. This means even with a
perfectly correct pipeline, our 1964 - last_old values will NOT match the
author's exactly. The expected pattern is high correlation, mean ~ 0,
and a small uniform-ish scaling difference. This is by design.

Author: Henry Chen
Date: 2026-04-28
*/
//----------------------------------------------------------------------------//

clear
set more off

global data   "`c(pwd)'\Data"
global output "`c(pwd)'\Output"
global temp   "`c(pwd)'\Temp"


//----------------------------------------------------------------------------//
**# Load author's original
//----------------------------------------------------------------------------//
import excel using "$data\model implied ICS 20220419.xlsx", ///
    sheet("Sheet1") firstrow clear
keep year ICS
rename ICS ICS_author
qui summ year
local last_old  = r(max)
local first_old = r(min)
tempfile author_orig
save `author_orig'


//----------------------------------------------------------------------------//
**# Load our reconstruction and overlap
//----------------------------------------------------------------------------//
use "$temp\ics_raw", clear
keep year ICS
rename ICS ICS_ours

merge 1:1 year using `author_orig', keep(match) nogen
keep if inrange(year, `first_old', `last_old')
sort year


//----------------------------------------------------------------------------//
**# Diagnostics
//----------------------------------------------------------------------------//
gen diff     = ICS_ours - ICS_author
gen abs_diff = abs(diff)
gen sq_diff  = diff^2

qui corr ICS_ours ICS_author
local corr_full = r(rho)

qui corr ICS_ours ICS_author if year <= 2013
local corr_in_sample = r(rho)

qui corr ICS_ours ICS_author if year >= 2014
local corr_post = r(rho)

qui summ ICS_author
local sd_a = r(sd)
local mean_a = r(mean)

qui summ ICS_ours
local sd_o = r(sd)
local mean_o = r(mean)

qui summ sq_diff, meanonly
local rmse = sqrt(r(mean))

qui summ abs_diff
local maxgap = r(max)

// Implied uniform scale factor (no constant)
qui reg ICS_author ICS_ours, nocons
local beta_scale = _b[ICS_ours]

di as text _n "==================== SANITY CHECK ===================="
di as text "Window: `first_old' - `last_old'"
di as text "------------------------------------------------------"
di as text "Correlation (full window)   : " %6.4f `corr_full'
di as text "Correlation (1964 - 2013)   : " %6.4f `corr_in_sample'
di as text "Correlation (2014 - last)   : " %6.4f `corr_post'
di as text "------------------------------------------------------"
di as text "SD author = " %8.4f `sd_a' "    SD ours = " %8.4f `sd_o' ///
    "    ratio (ours/auth) = " %6.4f `sd_o'/`sd_a'
di as text "Mean author = " %8.4f `mean_a' "    Mean ours = " %8.4f `mean_o' ///
    "    diff = " %8.4f `mean_o' - `mean_a'
di as text "RMSE         : " %8.4f `rmse'
di as text "Max abs gap  : " %8.4f `maxgap'
di as text "Implied scale (author = beta * ours) : " %8.4f `beta_scale'
di as text "======================================================" _n


//----------------------------------------------------------------------------//
**# Save
//----------------------------------------------------------------------------//
keep year ICS_author ICS_ours diff abs_diff
order year ICS_author ICS_ours diff abs_diff

save "$output\diagnostic_LINEAR", replace
export delimited using "$output\diagnostic_LINEAR.csv", replace

di as result "Diagnostic saved to Output\diagnostic_LINEAR.{dta,csv}"
