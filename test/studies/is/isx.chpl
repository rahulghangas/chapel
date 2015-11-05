// isx.chpl
// 
// Port of ISx to Chapel, co-developed by Brad Chamberlain,
// Lydia Duncan, and Jacob Hemstad on 2015-10-30.  Based on
// the OpenSHMEM version available from:
//
//   https://github.com/ParRes/ISx
//

//
// Top priorities:
// - LocaleSpace -> BucketSpace/Buckets
// - timer insertion
// - performance analysis / chplvis


// TODO:
// * variants that we should try
//   - multiple buckets per locale w/out any atomic ints
//   - some sort of hybrid between the current 1 bucket per locale scheme
//     and the previous?


//
// TODO: What are the potential performance issues?
// * put as one message?
// * how do Ben's locality optimizations do?
// * does returning arrays cost us anything?  Do we leak them?
// * other?
// * (this would be a good chplvis demo)
//

use BlockDist, Barrier;

// strong:
// - totkeys = 2**27
// - compute keys per locale

// weak*:
// - keys per pe = 2**27
// - compute totkeys


//const ScalingSpace = domain(scaling);



/*
config const keysPer = 2**23

const defaultTotalKeys: [ScalingSpace] int = [keysPer, 
                                              keysPer*numLocales, 
                                              keysPer*numLocales,
                                              32];
*/

config type keyType = int(32);

// TODO: replace 'numLocales' below with 'numBuckets' and LocaleSpace
// with BucketSpace (or somesuch)??

//
// The following options respectively control...
// - whether or not to print debug information
// - whether or not to do a test run (results in small problem sizes)
// - whether or not to run quietly (squashes successful verification messages)
// - whether or not to print the execution time configuration
// - whether or not to print the number of locales used to run
//
config const debug = false,
             testrun = debug,
             quiet = false,
             printConfig = !quiet,
             printNumLocales = !quiet;


//
// Define three scaling modes: strong scaling, weak scaling, and
// weakISO (in which the number of buckets per locale is held
// constant.
//
enum scaling {strong, weak, weakISO};

//
// Which scaling mode should the program be run in?
//
config const mode = scaling.weak;

//
// The number of keys is defined in terms of 'n', though whether this
// represents the total number of keys or the number of keys per
// bucket depends on whether we're running in a strong or weak scaling
// mode.  When debugging, we run a smaller problem size.
//
config const n = if testrun then 32 else 2**27;

//
// The total number of keys
//
config const totalKeys = if mode == scaling.strong then n
                                                   else n * numLocales;

//
// The number of keys per locale -- this is approximate for strong
// scaling if the number of locales doesn't divide 'n' evenly.
//
config const keysPerLocale = if mode == scaling.strong then n/numLocales
                                                       else n;

//
// The maximum key value to use.  When debugging, use a small size.
//
config const maxKeyVal = if testrun then 32 else 2**28;

//
// When running in the weakISO scaling mode, this width of each bucket
// is fixed.  Otherwise, it's the largest key value divided by the
// number of locales.
//
config const bucketWidth = if mode == scaling.weakISO then 8192
                                                      else maxKeyVal/numLocales;

//
// This tells how large the receive buffer should be relative to the
// average number of keys per locale.
//
config const recvBuffFactor = 2.0,
             recvBuffSize = (totalKeys * recvBuffFactor): int;

//
// These specify the number of burn-in runs and number of experimental
// trials, respectively.  If the number of trials is zero, we exit
// after printing the configuration (useful for debugging problem size
// logic without doing anything intense).
//
config const numBurnInRuns = 1,
             numTrials = 1;


// TODO: add timers and timing printouts

if printConfig then
  printConfiguration();

if numTrials == 0 then
  exit(0);

const OnePerLocale = LocaleSpace dmapped Block(LocaleSpace);

var myBucketKeys: [OnePerLocale] [0..#recvBuffSize] int;
var recvOffset: [OnePerLocale] atomic int;
var verifyKeyCount: atomic int;

// TODO: better name?
var barrier = new Barrier(numLocales);

coforall loc in Locales do
  on loc {
    // SPMD here
    if myBucketKeys[here.id][0].locale != here then
      warning("Need to distribute myBucketKeys");
    //
    // The non-positive iterations represent burn-in runs, so don't
    // time those.  To reduce time spent in verification, verify only
    // the final timed run.
    //
    for i in 1-numBurnInRuns..numTrials do
      bucketSort(time=(i>0), verify=(i==numTrials));
  }

if debug {
  writeln("myBucketKeys =\n");
  for i in LocaleSpace do
    writeln(myBucketKeys[i]);
}
  

proc bucketSort(time = false, verify = false) {
  var myKeys = makeInput();

  var bucketSizes = countLocalBucketSizes(myKeys);
  if debug then writeln(here.id, ": bucketSizes = ", bucketSizes);

  //
  // TODO: Should we be able to support scans on arrays of atomics without a
  // .read()?
  //
  // TODO: We really want an exclusive scan, but Chapel's is inclusive... :(
  //
  var sendOffsets: [LocaleSpace] int = + scan bucketSizes.read();
  sendOffsets -= bucketSizes.read();
  if debug then writeln(here.id, ": sendOffsets = ", sendOffsets);

  //
  // TODO: should we pass our globals into/out of these routines?
  //
  var myBucketedKeys = bucketizeLocalKeys(myKeys, sendOffsets);
  exchangeKeys(sendOffsets, bucketSizes, myBucketedKeys);

  barrier.barrier();

  //
  // TODO: discussed with Jake a version in which the histogramming
  // (countLocalKeys) was done in parallel with the exchangeKeys;
  // the exchange keys task would write a "done"-style sync variable
  // when a put was complete and the task could begin aggressively
  // histogramming the next buffer's worth of data.  Use a cobegin
  // to kick off both of these tasks in parallel and know when they're
  // both done.
  //

  const keysInMyBucket = recvOffset[here.id].read();
  var myLocalKeyCounts = countLocalKeys(keysInMyBucket);

  if (verify) then
    verifyResults(keysInMyBucket, myLocalKeyCounts);

  //
  // reset for next iteration
  //
  recvOffset[here.id].write(0);
  barrier.barrier();
}


// TODO: Is all this returning of local arrays going to cause problems?


//
// TODO: introduce BucketSpace domain instead of LocaleSpace
//
// const BucketSpace = {0..#numBuckets);

inline proc bucketizeLocalKeys(myKeys, sendOffsets) {
  var bucketOffsets: [LocaleSpace] atomic int;

  bucketOffsets.write(sendOffsets);

  var myBucketedKeys: [0..#keysPerLocale] keyType;
  
  forall key in myKeys {
    const bucketIndex = key / bucketWidth;
    const idx = bucketOffsets[bucketIndex].fetchAdd(1);
    myBucketedKeys[idx] = key; 
  }

  if debug then
    writeln(here.id, ": myBucketedKeys = ", myBucketedKeys);

  return myBucketedKeys;
}


inline proc countLocalBucketSizes(myKeys) {
  // TODO: if adding numBuckets, change to that here
  var bucketSizes: [LocaleSpace] atomic int;

  forall key in myKeys {
    const bucketIndex = key / bucketWidth;
    bucketSizes[bucketIndex].add(1);
  }

  return bucketSizes;
}

// TODO: does emacs not highlight 'here'?


inline proc exchangeKeys(sendOffsets, bucketSizes, myBucketedKeys) {
  forall locid in LocaleSpace {
    //
    // perturb the destination locale by our ID to avoid bottlenecks
    //
    const dstlocid = (locid+here.id) % numLocales;
    const transferSize = bucketSizes[dstlocid].read();
    const dstOffset = recvOffset[dstlocid].fetchAdd(transferSize);
    const srcOffset = sendOffsets[dstlocid];
    //
    // TODO: are we implementing this with one communication?
    // If not, and we turn on Rafa's optimization, is it better?
    //
    myBucketKeys[dstlocid][dstOffset..#transferSize] = 
            myBucketedKeys[srcOffset..#transferSize];
  }

}


inline proc countLocalKeys(myBucketSize) {
  // TODO: what if we used a global histogram here instead?
  // Note that if we did so and moved this outside of the coforall,
  // we could also remove the barrier from within the coforall
  const myMinKeyVal = here.id * bucketWidth;
  var myLocalKeyCounts: [myMinKeyVal..#bucketWidth] atomic int;
  //
  // TODO: Can we use a ref/array alias to myBucketKeys[here.id] to avoid
  // redundant indexing?
  //
  forall i in 0..#myBucketSize do
    myLocalKeyCounts[myBucketKeys[here.id][i]].add(1);

  if debug then
    writeln(here.id, ": myLocalKeyCounts[", myMinKeyVal, "..] = ", 
            myLocalKeyCounts);

  return myLocalKeyCounts;
}

inline proc verifyResults(myBucketSize, myLocalKeyCounts) {
  //
  // verify that all of my keys are in the expected range (myKeys)
  //
  const myMinKeyVal = here.id * bucketWidth;
  const myKeys = myMinKeyVal..#bucketWidth;
  forall i in 0..#myBucketSize {
    const key = myBucketKeys[here.id][i];
    if !myKeys.member(key) then
      halt("got key value outside my range: "+key + " not in " + myKeys);
  }

  //
  // verify that histogram sums properly
  //
  const myTotalLocalKeys = + reduce myLocalKeyCounts.read();
  if myTotalLocalKeys != myBucketSize then
    halt("local key count mismatch:" + myTotalLocalKeys + " != " + myBucketSize);

  //
  //
  //
  verifyKeyCount.add(myBucketSize);
  barrier.barrier();
  if verifyKeyCount.read() != totalKeys then
    halt("total key count mismatch: " + verifyKeyCount.read() + " != " + totalKeys);

  if (!quiet && here.id == 0) then
    writeln("Verification successful!");
}


inline proc makeInput() {
  //
  // TODO: can we get this to work?
  // extern {
  // #include "pcg_basic.h"
  // }
  require "ref-version/pcg_basic.h", "ref-version/pcg_basic.c";

  extern type pcg32_random_t;
  extern proc pcg32_srandom_r(ref rng: pcg32_random_t, 
                              initstate: uint(64),
                              initseq: uint(64));
  extern proc pcg32_boundedrand_r(ref rng: pcg32_random_t, 
                                  bound: uint(32)
                                 ): uint(32);

  var rng: pcg32_random_t;
  var myKeys: [0..#keysPerLocale] keyType;

  //
  // Seed RNG
  //
  if (debug) then
    writeln(here.id, ": Calling pcg32_srandom_r with ", here.id);

  pcg32_srandom_r(rng, here.id:uint(64), here.id:uint(64));


  //
  // Fill local array
  //
  for key in myKeys do
    key = pcg32_boundedrand_r(rng, maxKeyVal.safeCast(uint(32))).safeCast(keyType);

  if (debug) then
    writeln(here.id, ": myKeys: ", myKeys);

  return myKeys;
}

proc printConfiguration() {
  // TODO: print out scaling mode
  writeln("total keys = ", totalKeys);
  writeln("keys per locale = ", keysPerLocale);
  writeln("bucketWidth = ", bucketWidth);
  writeln("maxKeyVal = ", maxKeyVal);
  if printNumLocales then
    writeln("numLocales = ", numLocales);
  writeln("numTrials = ", numTrials);
}

             
/*
const keysPerLocale = totalKeys / 

                                                      
proc defaultBucketWidth(mode: scaling) {
  select (mode) {
  when mode.strong:
  when mode.weak:
  when mode.weakiso:
  when mode.debug:
    return 32;
  otherwise:
    halt("Unexpected scaling mode in defaultMaxKeyVal()");
  }
}
                                                      
proc defaultMaxKeyVal(mode: scaling) {
  select (mode) {
  when mode.strong:
  when mode.weak:
  when mode.weakiso:
  when mode.debug:
    return 32;
  otherwise:
    halt("Unexpected scaling mode in defaultMaxKeyVal()");
  }
}

*/