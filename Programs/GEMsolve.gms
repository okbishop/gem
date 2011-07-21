* GEMsolve.gms


* Last modified by Dr Phil Bishop, 24/03/2011 (imm@ea.govt.nz)

set thisY(y) ;
*** To do:
*** Remove the word 'run' from wherever it is used to describe something other than 'runs', e.g. %runName%
*** Sort out the MIPtrace stuff
*** Sort out GEMsolve.log. Where does it go and how does it get there?
*** does each model type have the correct modelstat error condition driving the abort stmt?

$ontext
 This program continues sequentially from GEMdata. The GEMdata work file must be called
 at invocation. Note that GEMdata was invoked by restarting from the GEMGEMdeclarations
 work file. This program is followed by GEMreports.

 Code sections:
  1. Take care of preliminaries.
  2. Prepare the outcome-dependent input data; key user-specified settings are obtained from GEMstochastic.inc.
  3. Write the GEMdataGDX file.
  4. Set bounds, initial levels and, in some cases, fix variables to a specified level.
  5. Solve the model and collect results.


  x. Re-declare and/or initialise sets and parameters.
  x. Set bounds, initial levels and fixes, then solve the model and collect results.
  x. Prepare results to pass along to report codes in the form of a GDX file. 
  x. Dump results out to GDX files and rename/relocate certain output files.
  x. Move MIPtrace files to output directory and generate miptrace.bat.
  x. Create an awk script, which when executed, will produce a file containing the number of integer solutions per MIP model.
$offtext

* Track memory usage.
* Higher numbers are for more detailed information inside loops. Alternatively, on the command line, type: gams xxx profile=1
*option profile = 1 ;
*option profile = 2 ;
*option profile = 3 ;

option seed = 101 ;

* Turn the following stuff on/off as desired.
$offupper onempty inlinecom { } eolcom !
$offuelxref offuellist	
*$onuelxref  onuellist	
$offsymxref offsymlist
*$onsymxref  onsymlist


*===============================================================================================
* 1. Take care of preliminaries.

* Declare and create basic run-time reporting capability.
File rep "Write to a report"       / "%ProgPath%Report.txt" / ; rep.lw = 0 ; rep.ap = 1 ;
File con "Write to the console"    / con / ;                    con.lw = 0 ;

putclose rep 'Run: "%runName%"' / 'Scenario: "%scenarioName%"' / '  - started at ', system.time, ' on ' system.date ;

* Specify various .lst file and solver-related options.
if(%limitOutput% = 1, option limcol = 0, limrow = 0, sysout = off, solprint = off ; ) ; 
option reslim = 500, iterlim = 10000000 ;
*option solprint = on ;

* Select the solver and include the relevant solver options files:
option LP = %Solver%, MIP = %Solver%, RMIP = %Solver% ;
$include 'GEM%Solver%.gms'

* Capture the specified solve goal and intialise various settings related to the solve goal.
Set solveGoal(goal) 'User-selected solve goal' / %solveGoal% / ;
gem.reslim = 500 ;     disp.reslim = 300 ;
gem.optfile = 1 ;      disp.optfile = 0 ;
gem.optcr = 0.00001 ;  gem.optca = 0 ;
loop(solveGoal(goal),
  if(sameas(solveGoal,'QDsol'),  gem.optfile = 2 ; gem.optcr = %QDoptCr% ; gem.reslim = %QDsolSecs% ) ;
  if(sameas(solveGoal,'VGsol'),  gem.optfile = 3 ; gem.reslim = %VGsolSecs% ) ;
  if(sameas(solveGoal,'MinGap'), gem.optfile = 4 ; gem.reslim = %MinGapSecs% ) ;
) ;

* To suppress use of an options file, use the command: 'xxx.OptFile = 0 ;'. Or simply comment out the
* command that calls the options file for the specific model name.

* Turn on the following to use the GAMSCHK routines.
*option MIP=GAMSCHK ;



*===============================================================================================
* 2. Prepare the outcome-dependent input data; key user-specified settings are obtained from GEMstochastic.inc.

$include GEMstochastic.gms

* Compute the short-run marginal cost (and its components) for each generating plant, $/MWh.
totalFuelCost(g,y,outcomes) = 1e-3 * i_heatrate(g) * sum(mapg_f(g,f), ( i_fuelPrices(f,y) * outcomeFuelCostFactor(outcomes) + i_FuelDeliveryCost(g) ) ) ;

CO2taxByPlant(g,y,outcomes) = 1e-9 * i_heatrate(g) * sum((mapg_f(g,f),mapg_k(g,k)), i_co2tax(y) * outcomeCO2TaxFactor(outcomes) * (1 - i_CCSfactor(y,k)) * i_emissionFactors(f) ) ;

CO2CaptureStorageCost(g,y) = 1e-9 * i_heatrate(g) * sum((mapg_f(g,f),mapg_k(g,k)), i_CCScost(y,k) * i_CCSfactor(y,k) * i_emissionFactors(f) ) ;

SRMC(g,y,outcomes) = i_varOM(g) + totalFuelCost(g,y,outcomes) + CO2taxByPlant(g,y,outcomes) + CO2CaptureStorageCost(g,y) ;

* If SRMC is zero or negligible (< .05) for any plant, assign a positive small value.
SRMC(g,y,outcomes)$( SRMC(g,y,outcomes) < .05 ) = .001 * ord(g) / card(g) ;

* Capture the island-wide AC loss adjustment factors.
AClossFactors('ni') = %AClossesNI% ;
AClossFactors('si') = %AClossesSI% ;

* Transfer i_NrgDemand to NrgDemand and adjust for intraregional AC transmission losses and the outcome-specific energy factor.
NrgDemand(r,y,t,lb,outcomes) = sum(mapild_r(ild,r), (1 + AClossFactors(ild)) * i_NrgDemand(r,y,t,lb)) * outcomeNRGfactor(outcomes) ;

* Use the GWh of NrgDemand and hours per LDC block to compute ldcMW (MW).
ldcMW(r,y,t,lb,outcomes)$hoursPerBlock(t,lb) = 1e3 * NrgDemand(r,y,t,lb,outcomes) / hoursPerBlock(t,lb) ;

* Transfer i_peakLoadNZ/NI to peakLoadNZ/NI and adjust for embedded generation and the outcome-specific peak load factor.
peakLoadNZ(y,outcomes) = ( i_peakLoadNZ(y) + %embedAdjNZ% ) * outcomePeakLoadFactor(outcomes) ;
peakLoadNI(y,outcomes) = ( i_peakLoadNI(y) + %embedAdjNI% ) * outcomePeakLoadFactor(outcomes) ;

* Transfer hydro output for all hydro years from i_historicalHydroOutput to historicalHydroOutput (no outcome-specific adjustment factors at this time).
historicalHydroOutput(v,hY,m) = i_historicalHydroOutput(v,hY,m) ;



*===============================================================================================
* 3. Write the GEMdataGDX file.

$ontext

  This is how it was previously when GEMdata created GEMdataGDX and then GEMsolve got its data 
  from both GEMdataGDX and GDXinputfile.

* NB: The following symbols from input data file may have been changed in GEMdata. So procure from
*     GEMdataGDX rather than from GDXinputFile, or make commensurate change.
*     Sets: y, exist, commit, new, neverBuild
*     Parameters: i_nrgtxCapacity, i_txCapacityPO

* Get set y from %GEMdataGDX% rather than %GDXinputFile% (years to solve for may be less than years data was prepared for).
$gdxin '%ProgPath%%GEMdataGDX%'
$loaddc y

$gdxin "%DataPath%%GDXinputFile%"
* Load sets from input GDX file.
$loaddc k f g s o r e ild p ps tupg tgc t lb rc hY v m
$loaddc maps_r mapm_t movers wind renew minUtilTechs demandGen gas diesel
* Load parameters from input GDX file.
$load i_minUtilByTech i_maxNrgByFuel i_fuelQuantities
$load i_UnitLargestProp i_offlineReserve i_nameplate i_baseload i_minUtilisation i_refurbDecisionYear
$load i_fof i_heatrate i_PumpedHydroMonth i_PumpedHydroEffic i_fixedOM i_HVDCshr i_HVDClevy i_plantReservesCost
$load i_distdGenRenew i_distdGenFossil i_VOLLcap i_VOLLcost i_renewNrgShare i_renewCapShare
$load i_firstHydroYear i_hydroOutputAdj i_bigSIgen i_fkNI i_fkSI i_HVDClosses i_HVDClossesPO
$load i_txGrpConstraintsRHS i_txGrpConstraintsLHS i_maxReservesTrnsfr i_reserveReqMW i_txCapacity i_txCapacityPO
$load i_fuelPrices i_fuelDeliveryCost i_co2tax i_CCSFactor i_emissionFactors i_CCSCost i_varOM
$load i_NrgDemand i_peakLoadNZ i_peakLoadNI

* Make sure intraregional transmission capacities are zero.
i_txCapacity(r,r,ps) = 0 ; i_txCapacityPO(r,r,ps) = 0 ;


$gdxin '%ProgPath%%GEMdataGDX%'
* Load sets created in GEMdata.
$loaddc n firstYr allButFirstYr firstPeriod mapg_k mapg_f mapg_o mapg_r mapg_e mapg_ild mapild_r mapv_g thermalFuel
$loaddc exist commit new noExist nigen sigen schedHydroPlant pumpedHydroPlant moverExceptions validYrBuild integerPlantBuild linearPlantBuild possibleToBuild
$loaddc possibleToRefurbish possibleToEndogRetire endogenousRetireDecisnYrs endogenousRetireYrs validYrOperate
$loaddc slackBus regLower interIsland nwd swd paths transitions validTransitions allowedStates notAllowedStates upgradedStates
$loaddc txEarlyComYrSet txFixedComYrSet validTGC nSegment
* Load parameters created in GEMdata.
$loaddc yearNum hydroYearNum lastHydroYear hoursPerBlock PVfacG PVfacT SRMC initialCapacity capCharge refurbCapCharge txCapCharge exogMWretired continueAftaEndogRetire
$loaddc peakConPlant NWpeakConPlant reservesCapability maxCapFactPlant minCapFactPlant ldcMW peakLoadNZ peakLoadNI bigNIgen nxtbigNIgen
$loaddc locFac_Recip susceptanceYr BBincidence bigLoss slope intercept reserveViolationPenalty windCoverPropn bigM
$loaddc singleReservesReqF historicalHydroOutput
*+++++++++++++++++++++++++
* More code to do the non-free reserves stuff. 
$loaddc freeReserves pNFresvCap pNFresvCost
*+++++++++++++++++++++++++
$offtext


Execute_Unload "%GEMdataGDX%",
*+++++++++++++++++++++++++
* More code to do the non-free reserves stuff. 
  freeReserves nonFreeReservesCap bigSwd bigNwd pNFresvCap pNFresvCost
*+++++++++++++++++++++++++
* Sets
* Re-declared and initialised
  y ct d dt n
* Time/date-related sets
  firstYr lastYr allButFirstYr firstPeriod
* Various mappings, subsets and counts.
  mapg_k mapg_f mapg_o mapg_i mapg_r mapg_e mapg_ild mapg_fc mapi_r mapi_e mapild_r mapv_g thermalFuel
* Financial
* Fuel prices and quantity limits.
* Generation data.
  exist commit new neverBuild
  noExist nigen sigen schedHydroPlant pumpedHydroPlant moverExceptions validYrBuild integerPlantBuild linearPlantBuild
  possibleToBuild possibleToRefurbish possibleToEndogRetire possibleToRetire endogenousRetireDecisnYrs endogenousRetireYrs
  validYrOperate
* Load data.
* Transmission data.
  slackBus regLower interIsland nwd swd paths uniPaths biPaths transitions validTransitions allowedStates notAllowedStates
  upgradedStates txEarlyComYrSet txFixedComYrSet validTGC nSegment
* Parameters
* Time/date-related sets and parameters.
  lastYear yearNum hydroYearNum lastHydroYear hoursPerBlock
* Various mappings, subsets and counts.
  numReg
* Financial parameters.
  CBAdiscountRates PVfacG PVfacT PVfacsM PVfacsEY PVfacs capexLife annuityFacN annuityFacR txAnnuityFacN txAnnuityFacR
  capRecFac depTCrecFac txCapRecFac txDeptCRecFac
* Fuel prices and quantity limits.
  SRMC totalFuelCost CO2taxByPlant CO2CaptureStorageCost
* Generation data.
  initialCapacity capitalCost capexPlant capCharge refurbCapexPlant refurbCapCharge exogMWretired continueAftaEndogRetire
  WtdAvgFOFmultiplier reservesCapability peakConPlant NWpeakConPlant maxCapFactPlant minCapFactPlant
* Load data.
  AClossFactors NrgDemand ldcMW peakLoadNZ peakLoadNI bigNIgen nxtbigNIgen
* Transmission data.
  locFac_Recip txEarlyComYr txFixedComYr reactanceYr susceptanceYr BBincidence pCap pLoss bigLoss slope intercept
  txCapitalCost txCapCharge
* Reserve energy data.
  reservesAreas reserveViolationPenalty windCoverPropn bigM singleReservesReqF
* Hydrology output data.
  historicalHydroOutput
  ;



*===============================================================================================
* 4. Set bounds, initial levels and, in some cases, fix variables to a specified level.

* Fix CGEN to zero for all years less than cGenYr and fix BGEN to zero for all years greater than or equal to cGenYr.
CGEN.up(g,y) = 1 ;     CGEN.fx(g,y)$( yearNum(y) <  cGenYr ) = 0 ;
BGEN.up(g,y) = 1 ;     BGEN.fx(g,y)$( yearNum(y) >= cGenYr ) = 0 ;

* Restrict refurbishment cost to be zero in years prior to refurbishment.
REFURBCOST.fx(g,y)$( yearNum(y) < i_refurbDecisionYear(g) ) = 0 ;

* Restrict generation:
* Don't allow generation unless the unit is in validYrOperate; validYrOperate embodies the appropriate date for existing, committed, and new units.
GEN.fx(g,y,t,lb,outcomes)$( not validYrOperate(g,y,t) ) = 0 ;
* Force generation from the must-run plant, i.e base load (convert MW capacity to GWh for each load block).
GEN.fx(g,y,t,lb,outcomes)$( ( exist(g) or commit(g) ) * i_baseload(g) * validYrOperate(g,y,t) ) =
1e-3 * hoursPerBlock(t,lb) * i_nameplate(g) * maxCapFactPlant(g,t,lb) ;

* Place restrictions on VOLL plants:
VOLLGEN.up(s,y,t,lb,outcomes) = 1e-3 * hoursPerBlock(t,lb) * i_VOLLcap(s) ;  ! Respect the capacity of VOLL plants
VOLLGEN.fx(s,y,t,lb,outcomes)$( ord(lb) <= noVOLLblks ) = 0 ;                ! Don't allow VOLL in user-specified top load blocks 

* Fix bounds on TX according to the largest capacity allowed in any state. Lower bound must be zero if transportation formulation is being used.
TX.lo(paths,y,t,lb,outcomes) = -smax(ps, i_txCapacity(paths,ps)) ;
TX.lo(paths,y,t,lb,outcomes)$(DCloadFlow = 0) = 0 ;
TX.up(paths,y,t,lb,outcomes) = +smax(ps, i_txCapacity(paths,ps)) ;

* Fix the reference bus angle to zero (only used in case of DC load flow formulation).
THETA.fx(slackBus(r),y,t,lb,outcomes) = 0 ;

* Fix various reserves variables to zero if they are not needed.
RESV.fx(g,rc,y,t,lb,outcomes)$(            ( not useReserves ) or ( not reservesCapability(g,rc) ) ) = 0 ;
RESVVIOL.fx(rc,ild,y,t,lb,outcomes)$(        not useReserves ) = 0 ;
RESVTRFR.fx(rc,ild,ild1,y,t,lb,outcomes)$( ( not useReserves ) or singleReservesReqF(rc) ) = 0 ;
RESVREQINT.fx(rc,ild,y,t,lb,outcomes)$(      not useReserves ) = 0 ;
NORESVTRFR.fx(ild,ild1,y,t,lb,outcomes)$(    not useReserves ) = 0 ;

* Fix to zero the intra-island reserve variables.
RESVTRFR.fx(rc,ild,ild,y,t,lb,outcomes) = 0 ;
NORESVTRFR.fx(ild,ild,y,t,lb,outcomes)  = 0 ;

* Set the lower bound on the reserve requirement if there is an external requirement specified.
RESVREQINT.lo(rc,ild,y,t,lb,outcomes)$( i_reserveReqMW(y,ild,rc) > 0 ) = i_reserveReqMW(y,ild,rc) * hoursPerBlock(t,lb) ;

* Reserve contribution cannot exceed the specified capability during peak or other periods.
RESV.up(g,rc,y,t,lb,outcomes)$( useReserves and reservesCapability(g,rc) ) = reservesCapability(g,rc) * hoursPerBlock(t,lb) ;

* Don't allow reserves from units prior to committed date or earliest allowable operation or if plant is retired.
RESV.fx(g,rc,y,t,lb,outcomes)$( not validYrOperate(g,y,t) ) = 0 ;



*===============================================================================================
* 5. Loop through all the runs

$set AddUpSlacks "sum((y,oc), SEC_NZ_PENALTY.l(y,oc) + SEC_NI_PENALTY.l(y,oc) + NOWIND_NZ_PENALTY.l(y,oc) + NOWIND_NI_PENALTY.l(y,oc) + ANNMWSLACK.l(y) + RENCAPSLACK.l(y) + HYDROSLACK.l(y) + MINUTILSLACK.l(y) + FUELSLACK.l(y) )"


* First, loop through all the experiments
loop(experiments,
* Reset any variables that might have been fixed for an earlier reoptimisation or dispatch run

* Restrict the build variable (i.e. MW) to zero or i_nameplate under certain input assumptions:
  BUILD.lo(g,y) = 0 ;
  BUILD.up(g,y) = i_nameplate(g) ;                                   ! Upper bound equals i_nameplate
  BUILD.fx(g,y)$( not validYrBuild(g,y) ) = 0 ;                      ! Don't allow capacity to be built in years outside the valid range of build years.
  BUILD.fx(g,y)$( commit(g) * validYrBuild(g,y) ) = i_nameplate(g) ; ! For committed plant, fix the MW able to be built regardless of any other settings.

* Fix retired MW by year and generating plant to zero if not able to be endogenously retired.
  RETIRE.lo(g,y) = 0 ; RETIRE.up(g,y) = inf ;
  RETIRE.fx(g,y)$( not endogenousRetireYrs(g,y) ) = 0 ;

* Fix the endogenous retirement binaries at zero for all cases where it's not required.
  BRET.lo(g,y) = 0 ;
  BRET.up(g,y) = 1 ;     BRET.fx(g,y)$( not endogenousRetireDecisnYrs(g,y) ) = 0 ;
  ISRETIRED.lo(g) = 0 ;
  ISRETIRED.up(g) = 1 ;  ISRETIRED.fx(g)$( not possibleToEndogRetire(g) ) = 0 ;

* Impose upper bound of 1 on continuous 0-1 transmission-related variables.
  TXUPGRADE.lo(r,rr,ps,pss,y) = 0 ;
  TXUPGRADE.up(validTransitions(paths,ps,pss),y) = 1 ;
  TXPROJVAR.lo(tupg,y) = 0 ;
  TXPROJVAR.up(tupg,y) = 1 ;

* Force transmission upgrades in the user-specified year (do this in either endogogenous or exogenous investment mode).
  loop((transitions(tupg,r,rr,ps,pss),y)$txFixedComYrSet(tupg,r,rr,ps,pss,y),
    TXUPGRADE.fx(r,rr,ps,pss,y) = 1 ;
  ) ;

* Fix the years prior to earliest year at zero for either exogenous or endogenous transmission investment.
  loop((transitions(tupg,r,rr,ps,pss),y)$txEarlyComYrSet(tupg,r,rr,ps,pss,y),
    TXUPGRADE.fx(r,rr,ps,pss,y) = 0 ;
  ) ;

* Fix transmission binaries to zero if they're not needed.
  BTX.lo(paths,ps,y) = 0 ;
  BTX.up(paths,ps,y) = 1 ;
  BTX.fx(notAllowedStates,y) = 0 ;


* Now, loop through each of the steps: timing, reopt and dispatch
  loop(steps,

    if(sameas(steps, 'reopt'),
*     If it's a reoptimisation run, fix the build (generation and transmission) to be the same as for the timing solve, but free up the movers.
      BUILD.fx(g,y) = BUILD.l(g,y) ;

      TXPROJVAR.fx(tupg,y) = TXPROJVAR.l(tupg,y) ;
      TXUPGRADE.fx(validTransitions(paths,ps,pss),y) = TXUPGRADE.l(paths,ps,pss,y) ;
      BTX.fx(paths,ps,y) = BTX.l(paths,ps,y) ;

      loop((g,movers(k))$( (noExist(g) * mapg_k(g,k)) * (not moverExceptions(g)) ),
        BUILD.lo(g,y)$validYrBuild(g,y) = 0 ;
        BUILD.up(g,y)$validYrBuild(g,y) = i_nameplate(g) ;
      ) ;

*     Fix the retirements to be the same as for the timing solve.
      BRET.fx(g,y) = BRET.l(g,y) ; ISRETIRED.fx(g) = ISRETIRED.l(g) ; RETIRE.fx(g,y) = RETIRE.l(g,y) ;

    elseif(sameas(steps, 'dispatch')),
*     If it's a dispatch solve then fix the investment timing decisions (of generation, refurbishment, and transmission) and the retirements from the timing solve(s).
      BUILD.fx(g,y) = BUILD.l(g,y) ;

      BRET.fx(g,y) = BRET.l(g,y) ;
      ISRETIRED.fx(g) = ISRETIRED.l(g) ;
      RETIRE.fx(g,y) = RETIRE.l(g,y) ;

      TXPROJVAR.fx(tupg,y) = TXPROJVAR.l(tupg,y) ;
      TXUPGRADE.fx(validTransitions(paths,ps,pss),y) = TXUPGRADE.l(paths,ps,pss,y) ;
      BTX.fx(paths,ps,y) = BTX.l(paths,ps,y) ;

*   End of step-type if
    ) ;

*   Loop over each scenario set for this step of the experiment
    loop(allRuns(experiments,steps,outcomeSets),

*     Initialise the desired outcomes for this run
      oc(outcomes) = no ;
      oc(outcomes)$setOutcomes(outcomeSets,outcomes) = yes ;
      display 'Outcomes for this run:', oc ;

*     Select the appropriate outcome weight in order to do the current timing solve.
      outcomeWeight(oc) = 0 ;
      outcomeWeight(oc) = set_outcomeWeight(outcomeSets,oc) ;
      display 'Outcome weight:', outcomeWeight ;

*     Compute the hydro output values to use for the selected outcomes (NB: only works for hydroSeqTypes={same,sequential}).
      modelledHydroOutput(g,y,t,outcomes) = 0 ;
      loop(oc(outcomes),
        if(mapOC_hydroSeqTypes(outcomes,'same'),
          modelledHydroOutput(g,y,t,outcomes) = hydroOutputScalar * i_hydroOutputAdj(y) *
            sum((mapv_g(v,g),mapm_t(m,t),hY1)$(mapOC_hY(outcomes,hY1)), historicalHydroOutput(v,hY1,m)) / sum(mapOC_hY(outcomes,hY), 1) ;
        else
          loop(y,
            chooseHydroYears(hY) = no ;
            chooseHydroYears(hY)$(sum(hY1$(mapOC_hY(outcomes, hY1) and ord(hY1) + ord(y) - 1            = ord(hY)), 1)) = yes ;
            chooseHydroYears(hY)$(sum(hY1$(mapOC_hY(outcomes, hY1) and ord(hY1) + ord(y) - 1 - card(hY) = ord(hY)), 1)) = yes ;
            modelledHydroOutput(g,y,t,oc) = ord(outcomes) * i_hydroOutputAdj(y) *
              sum((mapv_g(v,g),mapm_t(m,t),chooseHydroYears), historicalHydroOutput(v,chooseHydroYears,m)) / sum(chooseHydroYears, 1) ;
          ) ;
        ) ;
      ) ;
      display 'Hydro output:', modelledHydroOutput ;

*     Apply the selected solve goal for the investment timing solve.
      if(sameas(steps,'dispatch'),
        Solve DISP using %DISPtype% minimizing TOTALCOST ;
      else
        loop(solveGoal(goal),
*         Do the investment timing solve.
          Solve GEM using %GEMtype% minimizing TOTALCOST ;
        ) ;
      ) ;

*     Figure out if entire model invocation is to be aborted - but report that fact before aborting.
      slacks = %AddUpSlacks% ;
      counter = 0 ;
      if(sameas(steps,'dispatch'),
        counter$( DISP.modelstat <> 1 and DISP.modelstat <> 8 ) = 1 ;
      else
        counter$( ( GEM.modelstat = 10 ) or ( GEM.modelstat <> 1 and GEM.modelstat <> 8 ) ) = 1 ;
      ) ;

*     Post a progress message to report for use by GUI and to the console.
      if(counter = 1,
        putclose rep // 'The ' experiments.tl ' - ' steps.tl ' - ' outcomeSets.tl ' solve finished with some sort of problem and the job is now going to abort.' /
                        'Examine GEMsolve.lst and/or GEMsolve.log to see what went wrong.' ;
      else
        putclose rep // 'The ' experiments.tl ' - ' steps.tl ' - ' outcomeSets.tl ' solve finished at ', system.time / 'Objective function value: ' TOTALCOST.l:<12:1 / ;
      ) ;
      putclose con // '    The ' experiments.tl ' - ' steps.tl ' - ' outcomeSets.tl ' solve for "%runName% -- %scenarioName% has just finished' /
                      '    Objective function value: ' TOTALCOST.l:<12:1 // ;

      if(sameas(steps,'dispatch'),
        abort$( DISP.modelstat <> 1 and DISP.modelstat <> 8 ) "Problem encountered when solving DISP..." ;
      else
        abort$( GEM.modelstat = 10 ) "GEM is infeasible - check out GEMsolve.log to see what you've done wrong in configuring a model that is infeasible" ;
        abort$( GEM.modelstat <> 1 and GEM.modelstat <> 8 ) "Problem encountered solving GEM..." ;
      ) ;

*     Generate a MIP trace file when MIPtrace is equal to 1 (MIPtrace specified in GEMsettings).
$     if not %PlotMIPtrace%==1 $goto NoTrace3
      putclose bat 'copy MIPtrace.txt "%runName%-%scenarioName%-MIPtrace-' experiments.tl ' - ' steps.tl ' - ' outcomeSets.tl '.txt"' ;
      execute 'temp.bat';
$     label NoTrace3

*     Collect information for solve summary report
      solveReport(allRuns,'ObjFnValue') = TOTALCOST.l ;    solveReport(allRuns,'OCcosts') = sum(oc(outcomes), OUTCOME_COSTS.l(oc) ) ;
      solveReport(allRuns,'OptFile')    = gem.optfile ;    solveReport(allRuns,'OptCr')   = gem.optcr ;
      solveReport(allRuns,'ModStat')    = gem.modelstat ;  solveReport(allRuns,'SolStat') = gem.solvestat ;
      solveReport(allRuns,'Vars')       = gem.numvar ;     solveReport(allRuns,'DVars')   = gem.numdvar ;
      solveReport(allRuns,'Eqns')       = gem.numequ ;     solveReport(allRuns,'Iter')    = gem.iterusd ;
      solveReport(allRuns,'Time')       = gem.resusd ;     solveReport(allRuns,'GapAbs')  = abs( gem.objest - gem.objval ) ;
      solveReport(allRuns,'Gap%')$gem.objval = 100 * abs( gem.objest - gem.objval ) / gem.objval ;
      if(slacks > 0, solveReport(allRuns,'Slacks') = 1 else solveReport(allRuns,'Slacks') = -99 ) ;
      display solveReport, slacks ;

*     Collect up solution values - by experiment, step and scenarioSet.
$     include CollectResults.txt

*   End of scenario sets loop
    ) ;

* End of steps loop
  ) ;

* End of experiments loop
) ;



*===============================================================================================
* 5. Prepare results to pass along to report codes in the form of a GDX file. 

** Beware - what is now s2 was previously s3.
** What is happenning here is that the for each run type, the s_ params are being averaged over all hY and collected
** into the s2 params. Hence, we lose the hY domain on s2, otherwise all else (including explanatory text) is identical
** to the s_ param. Be aware that averaging over hY makes no sense for TMG and REO if they ever get done for more than one
** hY (which to date they have not been). But this may change when we code up Geoff's stochastic stuff. 

set sumRuns(outcomeSets) ;
parameter numRuns ;

loop(experiments,
  loop(steps,
    sumRuns(outcomeSets) = no;
    sumRuns(outcomeSets)$allRuns(experiments,steps,outcomeSets) = yes;
    numRuns = sum(sumRuns, 1);

    s2_TOTALCOST(experiments,steps)                          = sum(sumRuns, s_TOTALCOST(experiments,steps,sumRuns)) / numRuns ;
    s2_TX(experiments,steps,paths,y,t,lb,oc)                 = sum(sumRuns, s_TX(experiments,steps,sumRuns,paths,y,t,lb,oc) ) / numRuns ;
    s2_BRET(experiments,steps,g,y)                           = sum(sumRuns, s_BRET(experiments,steps,sumRuns,g,y) ) / numRuns ;
    s2_ISRETIRED(experiments,steps,g)                        = sum(sumRuns, s_ISRETIRED(experiments,steps,sumRuns,g) ) / numRuns ;
    s2_BTX(experiments,steps,paths,ps,y)                     = sum(sumRuns, s_BTX(experiments,steps,sumRuns,paths,ps,y) ) / numRuns ;
    s2_REFURBCOST(experiments,steps,g,y)                     = sum(sumRuns, s_REFURBCOST(experiments,steps,sumRuns,g,y) ) / numRuns ;
    s2_BUILD(experiments,steps,g,y)                          = sum(sumRuns, s_BUILD(experiments,steps,sumRuns,g,y) ) / numRuns ;
    s2_RETIRE(experiments,steps,g,y)                         = sum(sumRuns, s_RETIRE(experiments,steps,sumRuns,g,y) ) / numRuns ;
    s2_CAPACITY(experiments,steps,g,y)                       = sum(sumRuns, s_CAPACITY(experiments,steps,sumRuns,g,y) ) / numRuns ;
    s2_TXCAPCHARGES(experiments,steps,paths,y)               = sum(sumRuns, s_TXCAPCHARGES(experiments,steps,sumRuns,paths,y) ) / numRuns ;
    s2_GEN(experiments,steps,g,y,t,lb,oc)                    = sum(sumRuns, s_GEN(experiments,steps,sumRuns,g,y,t,lb,oc) ) / numRuns ;
    s2_VOLLGEN(experiments,steps,s,y,t,lb,oc)                = sum(sumRuns, s_VOLLGEN(experiments,steps,sumRuns,s,y,t,lb,oc) ) / numRuns ;
    s2_PUMPEDGEN(experiments,steps,g,y,t,lb,oc)              = sum(sumRuns, s_PUMPEDGEN(experiments,steps,sumRuns,g,y,t,lb,oc) ) / numRuns ;
    s2_LOSS(experiments,steps,paths,y,t,lb,oc)               = sum(sumRuns, s_LOSS(experiments,steps,sumRuns,paths,y,t,lb,oc) ) / numRuns ;
    s2_TXPROJVAR(experiments,steps,tupg,y)                   = sum(sumRuns, s_TXPROJVAR(experiments,steps,sumRuns,tupg,y) ) / numRuns ;
    s2_TXUPGRADE(experiments,steps,paths,ps,pss,y)           = sum(sumRuns, s_TXUPGRADE(experiments,steps,sumRuns,paths,ps,pss,y) ) / numRuns ;
    s2_RESV(experiments,steps,g,rc,y,t,lb,oc)                = sum(sumRuns, s_RESV(experiments,steps,sumRuns,g,rc,y,t,lb,oc) ) / numRuns ;
    s2_RESVVIOL(experiments,steps,rc,ild,y,t,lb,oc)          = sum(sumRuns, s_RESVVIOL(experiments,steps,sumRuns,rc,ild,y,t,lb,oc) ) / numRuns ;
    s2_RESVTRFR(experiments,steps,rc,ild,ild1,y,t,lb,oc)     = sum(sumRuns, s_RESVTRFR(experiments,steps,sumRuns,rc,ild,ild1,y,t,lb,oc) ) / numRuns ;
    s2_RENNRGPENALTY(experiments,steps,y)                    = sum(sumRuns, s_RENNRGPENALTY(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_ANNMWSLACK(experiments,steps,y)                       = sum(sumRuns, s_ANNMWSLACK(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_SEC_NZ_PENALTY(experiments,steps,oc,y)                = sum(sumRuns, s_SEC_NZ_PENALTY(experiments,steps,sumRuns,oc,y) ) / numRuns ;
    s2_SEC_NI_PENALTY(experiments,steps,oc,y)                = sum(sumRuns, s_SEC_NI_PENALTY(experiments,steps,sumRuns,oc,y) ) / numRuns ;
    s2_NOWIND_NZ_PENALTY(experiments,steps,oc,y)             = sum(sumRuns, s_NOWIND_NZ_PENALTY(experiments,steps,sumRuns,oc,y) ) / numRuns ;
    s2_NOWIND_NI_PENALTY(experiments,steps,oc,y)             = sum(sumRuns, s_NOWIND_NI_PENALTY(experiments,steps,sumRuns,oc,y) ) / numRuns ;
    s2_RENCAPSLACK(experiments,steps,y)                      = sum(sumRuns, s_RENCAPSLACK(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_HYDROSLACK(experiments,steps,y)                       = sum(sumRuns, s_HYDROSLACK(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_MINUTILSLACK(experiments,steps,y)                     = sum(sumRuns, s_MINUTILSLACK(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_FUELSLACK(experiments,steps,y)                        = sum(sumRuns, s_FUELSLACK(experiments,steps,sumRuns,y) ) / numRuns ;
    s2_bal_supdem(experiments,steps,r,y,t,lb,oc)             = sum(sumRuns, s_bal_supdem(experiments,steps,sumRuns,r,y,t,lb,oc) ) / numRuns ;

*   More non-free reserves code.
    s2_RESVCOMPONENTS(experiments,steps,paths,y,t,lb,outcomes,stp) = sum(sumRuns, s_RESVCOMPONENTS(experiments,steps,sumRuns,paths,y,t,lb,outcomes,stp) ) / numRuns ;

* End of steps loop
  ) ;
* End of experiments loop
) ;

Display s2_TOTALCOST, solveReport ;



*===============================================================================================
* 7. Dump results out to GDX files and rename/relocate certain output files.

* Dump output prepared for report writing into a GDX file.
Execute_Unload "PreparedOutput - %runName% - %scenarioName%.gdx",
* Miscellaneous sets
  oc solveGoal
* Miscellaneous parameters
  solveReport
* The 's2' output parameters
  s2_TOTALCOST s2_TX s2_BRET s2_ISRETIRED s2_BTX s2_REFURBCOST s2_BUILD s2_RETIRE s2_CAPACITY s2_TXCAPCHARGES s2_GEN s2_VOLLGEN
  s2_PUMPEDGEN s2_LOSS s2_TXPROJVAR s2_TXUPGRADE s2_RESV s2_RESVVIOL s2_RESVTRFR s2_bal_supdem
*++++++++++
* More non-free reserves code.
  s2_RESVCOMPONENTS
*++++++++++
* The 's2' penalties and slacks
  s2_RENNRGPENALTY s2_SEC_NZ_PENALTY s2_SEC_NI_PENALTY s2_NOWIND_NZ_PENALTY s2_NOWIND_NI_PENALTY s2_ANNMWSLACK s2_RENCAPSLACK s2_HYDROSLACK s2_MINUTILSLACK s2_FUELSLACK
  ;

* Dump all 's' slacks and penalties into a GDX file.
Execute_Unload "Slacks and penalties - %runName% - %scenarioName%.gdx",
  s_RENNRGPENALTY s_SEC_NZ_PENALTY s_SEC_NI_PENALTY s_NOWIND_NZ_PENALTY s_NOWIND_NI_PENALTY s_ANNMWSLACK s_RENCAPSLACK s_HYDROSLACK s_MINUTILSLACK s_FUELSLACK
  ;

* Dump all variable levels and constraint marginals into a GDX file. 
Execute_Unload "Levels and marginals - %runName% - %scenarioName%.gdx",
*+++++++++++++++++++++++++
* More non-free reserves code.
  s_RESVCOMPONENTS s_calc_nfreserves s_resv_capacity
*+++++++++++++++++++++++++
* Free Variables
  s_TOTALCOST s_TX s_THETA
* Binary Variables
  s_BGEN s_BRET s_ISRETIRED s_BTX s_NORESVTRFR
* Positive Variables
  s_REFURBCOST s_GENBLDCONT s_CGEN s_BUILD s_RETIRE s_CAPACITY s_TXCAPCHARGES s_GEN s_VOLLGEN s_PUMPEDGEN s_SPILL s_LOSS s_TXPROJVAR s_TXUPGRADE
* Reserve variables
  s_RESV s_RESVVIOL s_RESVTRFR s_RESVREQINT
* Penalty and slack variables
  s_RENNRGPENALTY s_SEC_NZ_PENALTY s_SEC_NI_PENALTY s_NOWIND_NZ_PENALTY s_NOWIND_NI_PENALTY s_ANNMWSLACK s_RENCAPSLACK s_HYDROSLACK s_MINUTILSLACK s_FUELSLACK
* Equations (ignore the objective function)
  s_calc_refurbcost s_calc_txcapcharges s_bldgenonce s_buildcapint s_buildcapcont s_annnewmwcap s_endogpltretire s_endogretonce s_balance_capacity s_bal_supdem
  s_security_nz s_security_ni s_nowind_nz s_nowind_ni s_limit_maxgen s_limit_mingen s_minutil s_limit_fueluse s_limit_nrg
  s_minreq_rennrg s_minreq_rencap s_limit_hydro s_limit_pumpgen1 s_limit_pumpgen2 s_limit_pumpgen3 s_boundtxloss s_tx_capacity s_tx_projectdef s_tx_onestate
  s_tx_upgrade s_tx_oneupgrade s_tx_dcflow s_tx_dcflow0 s_equatetxloss s_txGrpConstraint s_resvsinglereq1 s_genmaxresv1
  s_resvtrfr1 s_resvtrfr2 s_resvtrfr3 s_resvrequnit s_resvreq2 s_resvreqhvdc s_resvtrfr4 s_resvtrfrdef s_resvoffcap s_resvreqwind
  ;

bat.ap = 0 ;
putclose bat
  'copy "%ProgPath%%GEMdataGDX%"                                "%OutPath%\%runName%\GDX\"' /
  'copy "PreparedOutput - %runName% - %scenarioName%.gdx"       "%OutPath%\%runName%\GDX\"' /
  'copy "Slacks and penalties - %runName% - %scenarioName%.gdx" "%OutPath%\%runName%\GDX\"' /
  'copy "Levels and marginals - %runName% - %scenarioName%.gdx" "%OutPath%\%runName%\GDX\"' /
  'copy "GEMsolve.log"                                          "%OutPath%\%runName%\%runName% - %scenarioName% - GEMsolve.log"' /
  ;
execute 'temp.bat' ;



$stop
$ontext
Do we need the slacks as s2?
What about BGEN, cGEN and GENBLDCONT that all used to get added up to be s_buildgen?

    s_buildgen(mt,hYr,g,y)         = BGEN.l(g,y) + CGEN.l(g,y) + GENBLDCONT.l(g,y) ;
    s3_modelledHydroOutput(mds,mt,g,y,t,outcomes)       = sum(s_solveindex(mds,mt,hYr), s2_modelledHydroOutput(mds,mt,hYr,g,y,t,outcomes)  ) ;

    s3_rennrgpenalty(mds,mt,y)                = sum(s_solveindex(mds,mt,hYr), s2_rennrgpenalty(mds,mt,hyr,y) ) ;
    s3_sec_nzslack(mds,mt,y)                  = sum(s_solveindex(mds,mt,hYr), s2_sec_nzslack(mds,mt,hyr,y) ) ;
    s3_sec_nislack(mds,mt,y)                  = sum(s_solveindex(mds,mt,hYr), s2_sec_nislack(mds,mt,hyr,y) ) ;
    s3_nowind_nzslack(mds,mt,y)               = sum(s_solveindex(mds,mt,hYr), s2_nowind_nzslack(mds,mt,hyr,y) ) ;
    s3_nowind_nislack(mds,mt,y)               = sum(s_solveindex(mds,mt,hYr), s2_nowind_nislack(mds,mt,hyr,y) ) ;
    s3_annmwslack(mds,mt,y)                   = sum(s_solveindex(mds,mt,hYr), s2_annmwslack(mds,mt,hyr,y) ) ;
    s3_rencapslack(mds,mt,y)                  = sum(s_solveindex(mds,mt,hYr), s2_rencapslack(mds,mt,hyr,y) ) ;
    s3_hydroslack(mds,mt,y)                   = sum(s_solveindex(mds,mt,hYr), s2_hydroslack(mds,mt,hyr,y) ) ;
    s3_minutilslack(mds,mt,y)                 = sum(s_solveindex(mds,mt,hYr), s2_minutilslack(mds,mt,hyr,y) ) ;
    s3_fuelslack(mds,mt,y)                    = sum(s_solveindex(mds,mt,hYr), s2_fuelslack(mds,mt,hyr,y) ) ;
  else
Order of var/eqn declarations
Binary Variables
  BGEN(g,y)                         'Binary variable to identify build year for new generation plant'
Positive Variables
  REFURBCOST(g,y)                   'Annualised generation plant refurbishment expenditure charge, $'
  GENBLDCONT(g,y)                   'Continuous variable to identify build year for new scalable generation plant - for plant in linearPlantBuild set'
  CGEN(g,y)                         'Continuous variable to identify build year for new scalable generation plant - for plant in integerPlantBuild set (CGEN or BGEN = 0 in any year)'
  BUILD(g,y)                        'New capacity installed by generating plant and year, MW'
$offtext



*===============================================================================================
*  5. Move MIPtrace files to output directory and generate miptrace.bat.

$if not %PlotMIPtrace%==1 $goto NoTrace
* Copy current MIPtrace files from the programs to the Traceplots directory, and erase MIPtrace files from programs directory. 
putclose bat 'copy "%runName%-%scenarioName%-MIPtrace*.txt" "%OutPath%\%runName%\Traceplots"' / 'erase *MIPtrace*.txt' ;
execute 'temp.bat';

* Create the batch file to call Matlab to make the MIPtrace plots - note that miptrace.bat will be invoked from RunGem.gms.
if(%MexOrMat% = 1,
  putclose miptrace '"%MatCodePath%plot_all_objective_traces.exe" "%OutPath%\%runName%\Traceplots" "%runName%" "%Solver% trace"' ;
  else
  putclose miptrace "call matlab /r ", '"plot_all_objective_traces(', "'%OutPath%\%runName%\Traceplots','%runName%',","'%Solver% trace'); exit", '"' ;
) ;
$label NoTrace



*===============================================================================================
*  6. Create an awk script which, when executed, will produce a file containing the number of integer solutions per MIP model.

$if %GEMtype%=="rmip" $goto NoMIP
$onecho > f.awk
/Restarting execution/ {
  ++count2
  if (count1>0) {
    print "Model: " name "  Integer solutions: " count1
    count1 = 0
  }
}

/^\* / {
  ++count1
}

/^--- LOOPS / {
# Assumes there will be 3 nested loops
  name = $NF
  getline
  name = name "-" $NF
  getline
  name = name "-" $NF
}
$offecho
$label NoMIP




* End of file.
$offtext
