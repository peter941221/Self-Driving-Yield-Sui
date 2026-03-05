module self_driving_yield::adapter_stubs_tests;

use self_driving_yield::cetus_amm;
use self_driving_yield::perp_hedge;
use self_driving_yield::rebalancer;
use self_driving_yield::yield_source;

#[test]
fun stubs_return_false() {
    assert!(!cetus_amm::is_available(), 0);
    assert!(!yield_source::is_available(), 0);
    assert!(!perp_hedge::is_available(), 0);
    assert!(!rebalancer::is_available(), 0);
}
