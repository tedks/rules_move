#[test_only]
module move_fixture::counter_tests;

use move_fixture::counter;

#[test]
fun doubles() { assert!(counter::double(21) == 42, 0); }

#[test]
fun doubles_zero() { assert!(counter::double(0) == 0, 1); }
