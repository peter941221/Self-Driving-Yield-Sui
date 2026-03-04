# Louper Selector Map

Source: LouperDump + 4byte.directory

Note: 4byte may have duplicate/colliding signatures. Use as guidance only; verify with on-chain ABI.


Facet: 0x0890CE86aE04f45b0d8c92FA1c0554D1Ba835739 (ALP)

┌──────────────┬───────────────────────────────────────────────┐
│ Selector     │ Signature                                     │
├──────────────┼───────────────────────────────────────────────┤
│ 0x4c8564cd   │ ALP()                                         │
│ 0x058ddbe5   │ USDCap()                                      │
│ 0x44a9ca3f   │ addFreeBurnWhitelist(address)                 │
│ 0xea64f5dc   │ alpPrice()                                    │
│ 0x48276b6f   │ burnAlp(address,uint256,uint256,address)      │
│ 0x63810c0d   │ burnAlpBNB(uint256,uint256,address)           │
│ 0xcb97f571   │ burnAlpWithSignature(uint256,uint256,address,bytes,bytes) │
│ 0x2d2f69c6   │ coolingDuration()                             │
│ 0x7ac3c02f   │ getSigner()                                   │
│ 0x083292aa   │ initAlpManagerFacet(address,address)          │
│ 0x896c0605   │ isFreeBurn(address)                           │
│ 0x7ba49b81   │ lastMintedTimestamp(address)                  │
│ 0xc375f765   │ mintAlp(address,uint256,uint256,bool)         │
│ 0x08cdd3a3   │ mintAlpBNB(uint256,bool)                       │
│ 0x32214619   │ mintAlpWithSignature(uint256,uint256,bool,bytes,bytes) │
│ 0xbaccd94d   │ removeFreeBurnWhitelist(address)              │
│ 0xfc666b73   │ setCoolingDuration(uint256)                   │
│ 0xb92aabb7   │ setMaxUSDCap(uint256)                          │
│ 0x6c19e783   │ setSigner(address)                             │
└──────────────┴───────────────────────────────────────────────┘


Facet: 0x5553F3B5E2fAD83edA4031a3894ee59e25ee90bF (Trading)

┌──────────────┬───────────────────────────────────────────────┐
│ Selector     │ Signature                                     │
├──────────────┼───────────────────────────────────────────────┤
│ 0x29d9ddce   │ addMargin(bytes32,uint96)                     │
│ 0xd8eb6e91   │ batchCloseTrade(bytes32[])                    │
│ 0x5177fd3b   │ closeTrade(bytes32)                           │
│ 0x703085c7   │ openMarketTrade((address,bool,address,uint96,uint80,uint64,uint64,uint64,uint24)) │
│ 0xb7aeae66   │ openMarketTradeBNB((address,bool,address,uint96,uint80,uint64,uint64,uint64,uint24)) │
│ 0x04eeaae9   │ settleLpFundingFee(uint256)                   │
│ 0xc7bf7464   │ updateTradeSl(bytes32,uint64)                 │
│ 0xe016f83f   │ updateTradeTp(bytes32,uint64)                 │
│ 0x1bf31c47   │ updateTradeTpAndSl(bytes32,uint64,uint64)      │
└──────────────┴───────────────────────────────────────────────┘


Facet: 0x28dE81Bc5B6164d8522ad32AD7D139A21fa1E3b4 (Reader)

┌──────────────┬───────────────────────────────────────────────┐
│ Selector     │ Signature                                     │
├──────────────┼───────────────────────────────────────────────┤
│ 0x0cf85bcc   │ getMarketInfo(address)                        │
│ 0xb75832db   │ getMarketInfos(address[])                     │
│ 0x429cbec2   │ getPendingTrade(bytes32)                      │
│ 0x2c5e754a   │ getPositionByHashV2(bytes32)                   │
│ 0xac6f50ec   │ getPositionsV2(address,address)               │
│ 0x515120a8   │ traderAssets(address[])                       │
└──────────────┴───────────────────────────────────────────────┘


Verification (example):

- `cast 4byte 0x703085c7`

- `cast call <diamond> "facetAddress(bytes4)(address)" 0x703085c7 --rpc-url <BSC_RPC>`
