//----------------------------------------------------------------------------//
/*
v3: model-implied ICS through fiscal year 2021, standardized over the
author's window 1964 - last_old (option (a)).

ICS = (0.046 * dEI_std + (-0.078) * dDK_std) * 100   [percent]

Standardization: mean / sd of dEI, dDK computed ONLY over 1964 - last_old,
where last_old = max(year) in Data\model implied ICS 20220419.xlsx.
That mean/sd is then applied to every year (including the new years up to
2021), so units are continuous with the author's series.

Sample: CRSP/Compustat-merged universe under new CIZ filters,
non-utility/non-financial, NYSE/AMEX/Nasdaq.

Author: Henry Chen
Date: 2026-04-28
*/
//----------------------------------------------------------------------------//


//----------------------------------------------------------------------------//
**# Setup
//----------------------------------------------------------------------------//
clear
set more off

global wrds      "wrds"
global crspstart "1962-12-01"
global crspend   "2021-12-31"
global compstart "1963-01-01"
global compend   "2021-12-31"

global data   "`c(pwd)'\Data"
global output "`c(pwd)'\Output"
global temp   "`c(pwd)'\Temp"

foreach dirpath in temp output {
    mata: st_numscalar("OK", direxists("$`dirpath'"))
    if scalar(OK) == 0 mkdir "$`dirpath'"
}


//----------------------------------------------------------------------------//
**# Read author's original to determine standardization window
//----------------------------------------------------------------------------//
import excel using "$data\model implied ICS 20220419.xlsx", ///
    sheet("Sheet1") firstrow clear
keep year ICS
rename ICS ICS_author
qui summ year
global last_old  = r(max)
global first_old = r(min)
di as text "Author's series spans $first_old - $last_old"
di as text "Standardization window: $first_old - $last_old"

save "$temp\author_orig_v3", replace


//----------------------------------------------------------------------------//
**# Step 1: CRSP monthly with CIZ common-stock + exchange filters via CCM
//----------------------------------------------------------------------------//
clear
odbc load, exec("SELECT l.gvkey, l.permno, l.linkprim, l.linkdt, l.linkenddt, s.permco, s.mthcaldt, s.mthprc, s.shrout, s.siccd, s.primaryexch FROM (SELECT gvkey, lpermno AS permno, linkprim, linkdt, linkenddt FROM crsp_a_ccm.ccmxpf_linktable WHERE linktype IN ('LU','LC') AND linkprim IN ('P','C')) AS l JOIN (SELECT permco, permno, mthcaldt, mthprc, shrout, siccd, primaryexch FROM crsp.msf_v2 WHERE securitytype='EQTY' AND securitysubtype='COM' AND sharetype='NS' AND issuertype IN ('ACOR','CORP') AND usincflg='Y' AND primaryexch IN ('N','A','Q') AND conditionaltype='RW' AND tradingstatusflg='A') AS s ON s.permno=l.permno WHERE s.mthcaldt >= '$crspstart' AND s.mthcaldt <= '$crspend'") dsn("$wrds")

replace linkenddt = date("$crspend","YMD") if missing(linkenddt)
keep if inrange(mthcaldt, linkdt, linkenddt)
drop if inrange(siccd, 4900, 4999) | inrange(siccd, 6000, 6999)

save "$temp\crsp_monthly_v3", replace


//----------------------------------------------------------------------------//
**# Step 2: Compustat annual
//----------------------------------------------------------------------------//
clear
odbc load, exec("SELECT gvkey, fyear, datadate, sstk, prstkc, dv, dltt, dlc, ppent FROM comp_na_daily_all.funda WHERE datadate BETWEEN DATE '$compstart' AND DATE '$compend' AND indfmt='INDL' AND popsrc='D' AND datafmt='STD' AND consol='C' AND curcd='USD' AND costat IN ('A','I')") dsn("$wrds")

drop if missing(fyear)
sort gvkey fyear datadate
bys gvkey fyear: keep if _n == _N
save "$temp\compustat_annual_v3", replace


//----------------------------------------------------------------------------//
**# Step 4: December ME panel
//   ME at firm level = sum across permnos within (gvkey, December year)
//   siccd / primaryexch carried from primary permno (linkprim='P')
//----------------------------------------------------------------------------//
use "$temp\crsp_monthly_v3", clear
keep if month(mthcaldt) == 12
gen calyear = year(mthcaldt)
gen me = abs(mthprc) * shrout / 1000   // millions

gen byte is_primary = (linkprim == "P")
gsort gvkey calyear -is_primary
by gvkey calyear: gen byte pick = (_n == 1)

preserve
    keep if pick == 1
    keep gvkey calyear siccd primaryexch
    tempfile primary_attrs
    save `primary_attrs'
restore

collapse (sum) me, by(gvkey calyear)
merge 1:1 gvkey calyear using `primary_attrs', keep(match) nogen

save "$temp\me_dec_v3", replace


//----------------------------------------------------------------------------//
**# Step 5: Firm-year master
//----------------------------------------------------------------------------//
use "$temp\compustat_annual_v3", clear
gen year = fyear
keep if inrange(year, 1963, 2021)

// Merge ME at year t (FF: Dec of fyear)
preserve
    use "$temp\me_dec_v3", clear
    rename calyear year
    rename me me_dec_t
    keep gvkey year me_dec_t siccd primaryexch
    tempfile me_t
    save `me_t'
restore
merge 1:1 gvkey year using `me_t', keep(match) nogen

// Merge ME at year t-1
preserve
    use "$temp\me_dec_v3", clear
    gen year = calyear + 1
    rename me me_dec_lag
    keep gvkey year me_dec_lag
    tempfile me_lag
    save `me_lag'
restore
merge 1:1 gvkey year using `me_lag', keep(match master) nogen

drop if inrange(siccd, 4900, 4999) | inrange(siccd, 6000, 6999)
gen me_avg = 0.5 * (me_dec_t + me_dec_lag)

save "$temp\firm_year_v3", replace


//----------------------------------------------------------------------------//
**# Step 6: dEI (in percent)
//----------------------------------------------------------------------------//
use "$temp\firm_year_v3", clear

gen byte has_threshold = !missing(sstk) & !missing(me_avg) & me_avg > 0
gen byte equity_issuer = (sstk >= 0.03 * me_avg) if has_threshold

preserve
    keep if has_threshold
    collapse (mean) ei = equity_issuer (sum) n_issuers = equity_issuer ///
             (count) n_firms = equity_issuer, by(year)
    replace ei = ei * 100                         // percent
    sort year
    tsset year
    gen dei = ei - L.ei                           // percentage-point change
    save "$temp\dei_v3", replace
restore


//----------------------------------------------------------------------------//
**# Step 7: dDK (in percent), top 1% by ME excluded
//----------------------------------------------------------------------------//
use "$temp\firm_year_v3", clear

bysort year: egen me_p99 = pctile(me_dec_t), p(99)
drop if me_dec_t > me_p99 & !missing(me_dec_t)

replace dltt = 0 if missing(dltt)
replace dlc  = 0 if missing(dlc)
drop if missing(ppent) | ppent <= 0

collapse (sum) sum_dltt=dltt sum_dlc=dlc sum_ppent=ppent ///
         (count) n_firms_dk = ppent, by(year)
gen dk = (sum_dltt + sum_dlc) / sum_ppent * 100   // percent
sort year
tsset year
gen ddk = dk - L.dk                                // percentage-point change

save "$temp\ddk_v3", replace


//----------------------------------------------------------------------------//
**# Step 8: Combine + standardize over 1964 - $last_old (option a)
//----------------------------------------------------------------------------//
use "$temp\dei_v3", clear
merge 1:1 year using "$temp\ddk_v3", nogen

keep if inrange(year, 1964, 2021)

foreach v in dei ddk {
    qui summ `v' if inrange(year, 1964, $last_old)
    gen `v'_std = (`v' - r(mean)) / r(sd)
    di as text "`v': mean = " %8.4f r(mean) ", sd = " %8.4f r(sd) ///
        " (over 1964-$last_old)"
}

save "$temp\factors_v3", replace


//----------------------------------------------------------------------------//
**# Step 9: Model-implied ICS in percent
//----------------------------------------------------------------------------//
gen ICS = (0.046 * dei_std + (-0.078) * ddk_std) * 100   // percent
keep year ei dei dei_std dk ddk ddk_std ICS n_firms n_firms_dk
order year ei dei dei_std dk ddk ddk_std ICS n_firms n_firms_dk

save "$temp\ics_raw_v3", replace


//----------------------------------------------------------------------------//
**# Step 12: Append to author's original; write extended xlsx + dta + csv
//----------------------------------------------------------------------------//
use "$temp\ics_raw_v3", clear
keep year ICS
rename ICS ICS_ours
merge 1:1 year using "$temp\author_orig_v3", nogen

gen ICS = ICS_author if year <= $last_old & !missing(ICS_author)
replace ICS = ICS_ours if year > $last_old
keep year ICS
sort year

save "$output\model_implied_ICS_20260428_v3", replace

// Sheet1 — main series (author verbatim through last_old, ours after)
export excel year ICS using "$output\model implied ICS 20260428 v3.xlsx", ///
    sheet("Sheet1") firstrow(variables) replace

// Components sheet — full computed pipeline 1964-2021
use "$temp\ics_raw_v3", clear
export excel year dei ddk dei_std ddk_std ICS n_firms n_firms_dk ///
    using "$output\model implied ICS 20260428 v3.xlsx", ///
    sheet("Components") firstrow(variables) sheetmodify

// CSV mirror of Sheet1
use "$output\model_implied_ICS_20260428_v3", clear
export delimited using "$output\model_implied_ICS_20260428_v3.csv", replace

di as result "Done. v3 model-implied ICS (1964-2021) written to Output\."
