// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../BaseScript.sol";
import {ETH_GAS_COMPENSATION} from "../../src/Dependencies/Constants.sol";
import {IBorrowerOperations} from "../../src/Interfaces/IBorrowerOperations.sol";
import "../../src/AddressesRegistry.sol";
import "../../src/ActivePool.sol";
import {BoldToken} from "../../src/BoldToken.sol";
import "../../src/BorrowerOperations.sol";
import "../../src/CollSurplusPool.sol";
import "../../src/DefaultPool.sol";
import "../../src/GasPool.sol";
import "../../src/HintHelpers.sol";
import "../../src/MultiTroveGetter.sol";
import "../../src/SortedTroves.sol";
import "../../src/StabilityPool.sol";
import "../../src/TroveNFT.sol";
import "../../src/CollateralRegistry.sol";
import "../../src/test/TestContracts/PriceFeedTestnet.sol";
import {WETHTester} from "../../src/test/TestContracts/WETHTester.sol";
import {TroveManager} from "../../src/TroveManager.sol";
import {IGovernance} from "V2-gov/src/interfaces/IGovernance.sol";
import {Governance} from "V2-gov/src/Governance.sol";
import {MetadataDeployment} from "../../src/test/TestContracts/MetadataDeployment.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20Faucet} from "../../src/test/TestContracts/ERC20Faucet.sol";
import {GovernanceToken} from "../../src/Soneta/GovernanceToken.sol";

contract DeployLiquity is BaseScript, MetadataDeployment {
    string constant WRAPPED_SONIC_NAME = "Wrapped Sonic";
    string constant BOLD_TOKEN_NAME = "Bold Token";
    string constant ADDRESSES_REGISTRY_NAME = "AddressesRegistry";
    string constant COLLATERAL_REGISTRY_NAME = "CollateralRegistry";
    string constant HINT_HELPERS_NAME = "HintHelpers";
    string constant MULTI_TROVE_GETTER_NAME = "MultiTroveGetter";
    string constant GOVERNANCE_NAME = "Governance";

    string constant BORROWER_OPERATIONS_NAME = "BorrowerOperations";
    string constant TROVE_MANAGER_NAME = "TroveManager";
    string constant TROVE_NFT_NAME = "TroveNFT";
    string constant STABILITY_POOL_NAME = "StabilityPool";
    string constant ACTIVE_POOL_NAME = "ActivePool";
    string constant DEFAULT_POOL_NAME = "DefaultPool";
    string constant GAS_POOL_NAME = "GasPool";
    string constant COLL_SURPLUS_POOL_NAME = "CollSurplusPool";
    string constant SORTED_TROVES_NAME = "SortedTroves";
    string constant PRICE_FEED_NAME = "PriceFeed";
    string constant GOVERNANCE_TOKEN_NAME = "GovernanceToken";
    string constant STAKING_NAME = "Staking";
    string constant WETH_TESTNET_NAME = "WETHTester";
    // Governance Constants
    uint128 constant REGISTRATION_FEE = 100e18;
    uint128 constant REGISTRATION_THRESHOLD_FACTOR = 0.001e18;
    uint128 constant UNREGISTRATION_THRESHOLD_FACTOR = 3e18;
    uint16 constant REGISTRATION_WARM_UP_PERIOD = 4;
    uint16 constant UNREGISTRATION_AFTER_EPOCHS = 4;
    uint128 constant VOTING_THRESHOLD_FACTOR = 0.03e18;
    uint88 constant MIN_CLAIM = 500e18;
    uint88 constant MIN_ACCRUAL = 1000e18;
    uint32 constant EPOCH_DURATION = 6 days;
    uint32 constant EPOCH_VOTING_CUTOFF = 1 days;

    // UniV4Donations Constants
    uint256 immutable VESTING_EPOCH_START = block.timestamp;
    uint256 constant VESTING_EPOCH_DURATION = 7 days;
    uint24 constant FEE = 400;
    int24 constant MAX_TICK_SPACING = 32767;

    bytes32 public SALT;
    address public deployer;

    struct TroveManagerParams {
        uint256 CCR;
        uint256 MCR;
        uint256 SCR;
        uint256 LIQUIDATION_PENALTY_SP;
        uint256 LIQUIDATION_PENALTY_REDISTRIBUTION;
    }

    struct LiquityContractAddresses {
        address activePool;
        address borrowerOperations;
        address collSurplusPool;
        address defaultPool;
        address sortedTroves;
        address stabilityPool;
        address troveManager;
        address troveNFT;
        address metadataNFT;
        address priceFeed;
        address gasPool;
        address interestRouter;
    }

    function run() external override {
        _loadContracts(false);

        SALT = keccak256(abi.encodePacked(block.timestamp));
        deployer = _getDeployerAddress();

        TroveManagerParams[] memory troveManagerParamsArray = new TroveManagerParams[](1);
        troveManagerParamsArray[0] = TroveManagerParams(150e16, 110e16, 110e16, 5e16, 10e16); // WETH
        // troveManagerParamsArray[1] = TroveManagerParams(150e16, 120e16, 110e16, 5e16, 10e16); // wstETH
        // troveManagerParamsArray[2] = TroveManagerParams(150e16, 120e16, 110e16, 5e16, 10e16); // rETH

        if (_isTestnet()) {
            _tryDeployContract(
                GOVERNANCE_TOKEN_NAME, 0, type(ERC20Faucet).creationCode, abi.encode("Soneta", "SON", 100e18, 1 days)
            );
            _tryDeployContract(WETH_TESTNET_NAME, 0, type(WETHTester).creationCode, abi.encode(0, type(uint256).max));
        } else {
            //TODO: should be a multisig
            contracts[WETH_TESTNET_NAME] = address(0);
            _tryDeployContract(GOVERNANCE_TOKEN_NAME, 0, type(GovernanceToken).creationCode, abi.encode(deployer));
        }

        address[] memory collaterals = new address[](1);
        collaterals[0] = contracts[WETH_TESTNET_NAME];

        _deployAndConnectContracts(troveManagerParamsArray, collaterals, contracts[WETH_TESTNET_NAME]);

        (address governanceAddress,) = deployGovernance();
        address computedGovernanceAddress =
            computeGovernanceAddress(deployer, SALT, IERC20(contracts[BOLD_TOKEN_NAME]), new address[](0));

        require(governanceAddress == computedGovernanceAddress, "Governance address mismatch");
    }

    function _deployAndConnectContracts(
        TroveManagerParams[] memory troveManagerParamsArray,
        address[] memory _collaterals,
        address _WETH
    ) internal {
        uint256 numCollaterals = troveManagerParamsArray.length;
        assert(_collaterals.length == numCollaterals);

        (address boldToken,) =
            _tryDeployContractCREATE2(BOLD_TOKEN_NAME, SALT, type(BoldToken).creationCode, abi.encode(deployer));
        address[] memory addressesRegistries = new address[](numCollaterals);
        address[] memory troveManagers = new address[](numCollaterals);

        for (uint256 i = 0; i < numCollaterals; ++i) {
            (IAddressesRegistry addressesRegistry, address troveManagerAddress) =
                _deployAddressesRegistry(_collaterals[i], troveManagerParamsArray[i]);
            addressesRegistries[i] = address(addressesRegistry);
            troveManagers[i] = troveManagerAddress;
        }

        _tryDeployContract(
            COLLATERAL_REGISTRY_NAME,
            0,
            type(CollateralRegistry).creationCode,
            abi.encode(boldToken, _asIERC20Array(_collaterals), troveManagers)
        );

        _tryDeployContract(
            HINT_HELPERS_NAME, 0, type(HintHelpers).creationCode, abi.encode(contracts[COLLATERAL_REGISTRY_NAME])
        );

        _tryDeployContract(
            MULTI_TROVE_GETTER_NAME,
            0,
            type(MultiTroveGetter).creationCode,
            abi.encode(contracts[COLLATERAL_REGISTRY_NAME])
        );

        // Deploy per-branch contracts for each branch
        for (uint256 i = 0; i < numCollaterals; ++i) {
            _deployAndConnectCollateralContractsTestnet(
                address(_collaterals[i]),
                IBoldToken(boldToken),
                ICollateralRegistry(contracts[COLLATERAL_REGISTRY_NAME]),
                IWETH(_WETH),
                IAddressesRegistry(addressesRegistries[i]),
                address(troveManagers[i]),
                IHintHelpers(contracts[HINT_HELPERS_NAME]),
                IMultiTroveGetter(contracts[MULTI_TROVE_GETTER_NAME])
            );
        }

        vm.broadcast(_getDeployerPrivateKey());
        BoldToken(boldToken).setCollateralRegistry(contracts[COLLATERAL_REGISTRY_NAME]);
    }

    function _asIERC20Array(address[] memory _addresses) internal pure returns (IERC20Metadata[] memory erc20s) {
        assembly {
            erc20s := _addresses
        }
    }

    function _deployAddressesRegistry(address _collateral, TroveManagerParams memory _troveManagerParams)
        internal
        returns (IAddressesRegistry, address troveManagerAddress_)
    {
        string memory name = IERC20Metadata(_collateral).symbol();
        (address addressesRegistry,) = _tryDeployContractCREATE2(
            string.concat(ADDRESSES_REGISTRY_NAME, name),
            SALT,
            type(AddressesRegistry).creationCode,
            abi.encode(
                deployer,
                _troveManagerParams.CCR,
                _troveManagerParams.MCR,
                _troveManagerParams.SCR,
                _troveManagerParams.LIQUIDATION_PENALTY_SP,
                _troveManagerParams.LIQUIDATION_PENALTY_REDISTRIBUTION
            )
        );

        troveManagerAddress_ = vm.computeCreate2Address(
            SALT, keccak256(abi.encodePacked(type(TroveManager).creationCode, abi.encode(addressesRegistry)))
        );

        return (IAddressesRegistry(addressesRegistry), troveManagerAddress_);
    }

    function _deployAndConnectCollateralContractsTestnet(
        address _collToken,
        IBoldToken _boldToken,
        ICollateralRegistry _collateralRegistry,
        IWETH _weth,
        IAddressesRegistry _addressesRegistry,
        address _troveManagerAddress,
        IHintHelpers _hintHelpers,
        IMultiTroveGetter _multiTroveGetter
    ) internal {
        LiquityContractAddresses memory addresses;
        LiquityContractAddresses memory deployedAddresses;

        address metadataNFT = address(deployMetadata(SALT));
        (address priceFeed,) = _tryDeployContract(PRICE_FEED_NAME, 0, type(PriceFeedTestnet).creationCode, "");

        addresses.interestRouter = computeGovernanceAddress(deployer, SALT, _boldToken, new address[](0));
        addresses.troveNFT = _computeAddress(type(TroveNFT).creationCode, abi.encode(_addressesRegistry));
        addresses.stabilityPool = _computeAddress(type(StabilityPool).creationCode, abi.encode(_addressesRegistry));
        addresses.activePool = _computeAddress(type(ActivePool).creationCode, abi.encode(_addressesRegistry));
        addresses.defaultPool = _computeAddress(type(DefaultPool).creationCode, abi.encode(_addressesRegistry));
        addresses.gasPool = _computeAddress(type(GasPool).creationCode, abi.encode(_addressesRegistry));
        addresses.sortedTroves = _computeAddress(type(SortedTroves).creationCode, abi.encode(_addressesRegistry));

        addresses.borrowerOperations =
            _computeAddress(type(BorrowerOperations).creationCode, abi.encode(_addressesRegistry));
        addresses.collSurplusPool = _computeAddress(type(CollSurplusPool).creationCode, abi.encode(_addressesRegistry));

        IAddressesRegistry.AddressVars memory addressVars = IAddressesRegistry.AddressVars({
            collToken: IERC20Metadata(_collToken),
            borrowerOperations: IBorrowerOperations(addresses.borrowerOperations),
            troveManager: ITroveManager(_troveManagerAddress),
            troveNFT: ITroveNFT(addresses.troveNFT),
            metadataNFT: IMetadataNFT(metadataNFT),
            stabilityPool: IStabilityPool(addresses.stabilityPool),
            priceFeed: IPriceFeedTestnet(priceFeed),
            activePool: IActivePool(addresses.activePool),
            defaultPool: IDefaultPool(addresses.defaultPool),
            gasPoolAddress: addresses.gasPool,
            collSurplusPool: ICollSurplusPool(addresses.collSurplusPool),
            sortedTroves: ISortedTroves(addresses.sortedTroves),
            interestRouter: IInterestRouter(addresses.interestRouter),
            hintHelpers: _hintHelpers,
            multiTroveGetter: _multiTroveGetter,
            collateralRegistry: _collateralRegistry,
            boldToken: _boldToken,
            WETH: _weth
        });

        vm.broadcast(_getDeployerPrivateKey());
        _addressesRegistry.setAddresses(addressVars);

        string memory collateralSymbol = IERC20Metadata(_collToken).symbol();

        (deployedAddresses.borrowerOperations,) = _tryDeployContractCREATE2(
            string.concat(BORROWER_OPERATIONS_NAME, "_", collateralSymbol),
            SALT,
            type(BorrowerOperations).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.troveManager,) = _tryDeployContractCREATE2(
            string.concat(TROVE_MANAGER_NAME, "_", collateralSymbol),
            SALT,
            type(TroveManager).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.troveNFT,) = _tryDeployContractCREATE2(
            string.concat(TROVE_NFT_NAME, "_", collateralSymbol),
            SALT,
            type(TroveNFT).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.stabilityPool,) = _tryDeployContractCREATE2(
            string.concat(STABILITY_POOL_NAME, "_", collateralSymbol),
            SALT,
            type(StabilityPool).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.activePool,) = _tryDeployContractCREATE2(
            string.concat(ACTIVE_POOL_NAME, "_", collateralSymbol),
            SALT,
            type(ActivePool).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.defaultPool,) = _tryDeployContractCREATE2(
            string.concat(DEFAULT_POOL_NAME, "_", collateralSymbol),
            SALT,
            type(DefaultPool).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.gasPool,) = _tryDeployContractCREATE2(
            string.concat(GAS_POOL_NAME, "_", collateralSymbol),
            SALT,
            type(GasPool).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.collSurplusPool,) = _tryDeployContractCREATE2(
            string.concat(COLL_SURPLUS_POOL_NAME, "_", collateralSymbol),
            SALT,
            type(CollSurplusPool).creationCode,
            abi.encode(_addressesRegistry)
        );
        (deployedAddresses.sortedTroves,) = _tryDeployContractCREATE2(
            string.concat(SORTED_TROVES_NAME, "_", collateralSymbol),
            SALT,
            type(SortedTroves).creationCode,
            abi.encode(_addressesRegistry)
        );

        require(
            deployedAddresses.borrowerOperations == addresses.borrowerOperations,
            "BorrowerOperations not same as computed address"
        );

        require(deployedAddresses.troveManager == _troveManagerAddress, "TroveManager not same as computed address");
        require(deployedAddresses.troveNFT == addresses.troveNFT, "TroveNFT not same as computed address");
        require(
            deployedAddresses.stabilityPool == addresses.stabilityPool, "StabilityPool not same as computed address"
        );
        require(deployedAddresses.activePool == addresses.activePool, "ActivePool not same as computed address");
        require(deployedAddresses.defaultPool == addresses.defaultPool, "DefaultPool not same as computed address");
        require(deployedAddresses.gasPool == addresses.gasPool, "GasPool not same as computed address");
        require(
            deployedAddresses.collSurplusPool == addresses.collSurplusPool,
            "CollSurplusPool not same as computed address"
        );
        require(deployedAddresses.sortedTroves == addresses.sortedTroves, "SortedTroves not same as computed address");

        vm.broadcast(_getDeployerPrivateKey());
        _boldToken.setBranchAddresses(
            _troveManagerAddress, addresses.stabilityPool, addresses.borrowerOperations, addresses.activePool
        );
    }

    function _computeAddress(bytes memory _bytecode, bytes memory _args) internal view returns (address) {
        return vm.computeCreate2Address(SALT, keccak256(abi.encodePacked(_bytecode, _args)));
    }

    function deployGovernance() internal returns (address, string memory) {
        (address governanceAddress, IGovernance.Configuration memory governanceConfiguration) =
        computeGovernanceAddressAndConfig(
            _getDeployerAddress(), SALT, IERC20(contracts[BOLD_TOKEN_NAME]), new address[](0)
        );

        (address governance,) = _tryDeployContractCREATE2(
            GOVERNANCE_NAME,
            SALT,
            type(Governance).creationCode,
            abi.encode(
                contracts[GOVERNANCE_TOKEN_NAME],
                contracts[BOLD_TOKEN_NAME],
                contracts[STAKING_NAME],
                contracts[BOLD_TOKEN_NAME],
                governanceConfiguration,
                _getDeployerAddress(),
                new address[](0)
            )
        );

        assert(governanceAddress == address(governance));
        // deployUniV4Donations(governance, _boldToken, _usdc);

        // Curve initiative
        //deployCurveV2GaugeRewards(governance, _boldToken);

        // governance.registerInitialInitiatives(initialInitiatives);

        return (governanceAddress, _getManifestJson());
    }

    function computeGovernanceAddress(
        address _deployer,
        bytes32 _salt,
        IERC20 _boldToken,
        address[] memory _initialInitiatives
    ) internal view returns (address) {
        (address governanceAddress,) =
            computeGovernanceAddressAndConfig(_deployer, _salt, _boldToken, _initialInitiatives);
        return governanceAddress;
    }

    function computeGovernanceAddressAndConfig(
        address _deployer,
        bytes32 _salt,
        IERC20 _boldToken,
        address[] memory _initialInitiatives
    ) internal view returns (address, IGovernance.Configuration memory) {
        IGovernance.Configuration memory governanceConfiguration = IGovernance.Configuration({
            registrationFee: REGISTRATION_FEE,
            registrationThresholdFactor: REGISTRATION_THRESHOLD_FACTOR,
            unregistrationThresholdFactor: UNREGISTRATION_THRESHOLD_FACTOR,
            registrationWarmUpPeriod: REGISTRATION_WARM_UP_PERIOD,
            unregistrationAfterEpochs: UNREGISTRATION_AFTER_EPOCHS,
            votingThresholdFactor: VOTING_THRESHOLD_FACTOR,
            minClaim: MIN_CLAIM,
            minAccrual: MIN_ACCRUAL,
            epochStart: uint32(block.timestamp - VESTING_EPOCH_START),
            /// @audit Ensures that `initialInitiatives` can be voted on
            epochDuration: EPOCH_DURATION,
            epochVotingCutoff: EPOCH_VOTING_CUTOFF
        });

        bytes memory bytecode = abi.encodePacked(
            type(Governance).creationCode,
            abi.encode(
                contracts[GOVERNANCE_TOKEN_NAME],
                address(_boldToken),
                contracts[STAKING_NAME],
                address(_boldToken),
                governanceConfiguration,
                _deployer,
                _initialInitiatives
            )
        );

        address governanceAddress = vm.computeCreate2Address(_salt, keccak256(bytecode));

        return (governanceAddress, governanceConfiguration);
    }

    function _getManifestJson() internal view returns (string memory) {
        return string.concat(
            "{",
            // string.concat(
            //     //string.concat('"constants":', _getGovernanceDeploymentConstants(), ","),
            //     string.concat('"governance":"', governance.toHexString(), '",'),
            //     string.concat('"uniV4DonationsInitiative":"', address(uniV4Donations).toHexString(), '",'),
            //     string.concat('"curveV2GaugeRewardsInitiative":"', address(curveV2GaugeRewards).toHexString(), '",'),
            //     string.concat('"curvePool":"', address(curvePool).toHexString(), '",'),
            //     string.concat('"gauge":"', address(gauge).toHexString(), '",'),
            //     string.concat('"LQTYToken":"', address(lqty).toHexString(), '" ') // no comma
            // ),
            "}"
        );
    }

    function _openTestTroves() internal {
        // if (vm.envOr("OPEN_DEMO_TROVES", false)) {
        //     // Anvil default accounts
        //     // TODO: get accounts from env
        //     uint256[] memory demoAccounts = new uint256[](8);
        //     demoAccounts[0] = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        //     demoAccounts[1] = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        //     demoAccounts[2] = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
        //     demoAccounts[3] = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
        //     demoAccounts[4] = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
        //     demoAccounts[5] = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
        //     demoAccounts[6] = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;
        //     demoAccounts[7] = 0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356;

        //     DemoTroveParams[] memory demoTroves = new DemoTroveParams[](16);

        //     demoTroves[0] = DemoTroveParams(0, demoAccounts[0], 0, 25e18, 2800e18, 5.0e16);
        //     demoTroves[1] = DemoTroveParams(0, demoAccounts[1], 0, 37e18, 2400e18, 4.7e16);
        //     demoTroves[2] = DemoTroveParams(0, demoAccounts[2], 0, 30e18, 4000e18, 3.3e16);
        //     demoTroves[3] = DemoTroveParams(0, demoAccounts[3], 0, 65e18, 6000e18, 4.3e16);

        //     demoTroves[4] = DemoTroveParams(0, demoAccounts[4], 0, 19e18, 2280e18, 5.0e16);
        //     demoTroves[5] = DemoTroveParams(0, demoAccounts[5], 0, 48.37e18, 4400e18, 4.7e16);
        //     demoTroves[6] = DemoTroveParams(0, demoAccounts[6], 0, 33.92e18, 5500e18, 3.8e16);
        //     demoTroves[7] = DemoTroveParams(0, demoAccounts[7], 0, 47.2e18, 6000e18, 4.3e16);

        //     demoTroves[8] = DemoTroveParams(1, demoAccounts[0], 1, 21e18, 2000e18, 3.3e16);
        //     demoTroves[9] = DemoTroveParams(1, demoAccounts[1], 1, 16e18, 2000e18, 4.1e16);
        //     demoTroves[10] = DemoTroveParams(1, demoAccounts[2], 1, 18e18, 2300e18, 3.8e16);
        //     demoTroves[11] = DemoTroveParams(1, demoAccounts[3], 1, 22e18, 2200e18, 4.3e16);

        //     demoTroves[12] = DemoTroveParams(1, demoAccounts[4], 1, 85e18, 12000e18, 7.0e16);
        //     demoTroves[13] = DemoTroveParams(1, demoAccounts[5], 1, 87e18, 4000e18, 4.4e16);
        //     demoTroves[14] = DemoTroveParams(1, demoAccounts[6], 1, 71e18, 11000e18, 3.3e16);
        //     demoTroves[15] = DemoTroveParams(1, demoAccounts[7], 1, 84e18, 12800e18, 4.4e16);

        //     for (uint256 i = 0; i < deployed.contractsArray.length; i++) {
        //         //give token to addresses
        //     }

        //     openDemoTroves(demoTroves, deployed.contractsArray);
        // }
    }

    // function openDemoTroves(DemoTroveParams[] memory demoTroves, LiquityContractsTestnet[] memory contractsArray)
    //     internal
    // {
    //     for (uint256 i = 0; i < demoTroves.length; i++) {
    //         DemoTroveParams memory trove = demoTroves[i];
    //         LiquityContractsTestnet memory contracts = contractsArray[trove.collIndex];

    //         vm.startBroadcast(trove.owner);

    //         IERC20 collToken = IERC20(contracts.collToken);
    //         IERC20 wethToken = IERC20(_addressesRegistry.WETH());

    //         // Approve collToken to BorrowerOperations
    //         if (collToken == wethToken) {
    //             wethToken.approve(address(contracts.borrowerOperations), trove.coll + ETH_GAS_COMPENSATION);
    //         } else {
    //             wethToken.approve(address(contracts.borrowerOperations), ETH_GAS_COMPENSATION);
    //             collToken.approve(address(contracts.borrowerOperations), trove.coll);
    //         }

    //         IBorrowerOperations(contracts.borrowerOperations).openTrove(
    //             vm.addr(trove.owner), //     _owner
    //             trove.ownerIndex, //         _ownerIndex
    //             trove.coll, //               _collAmount
    //             trove.debt, //               _boldAmount
    //             0, //                        _upperHint
    //             0, //                        _lowerHint
    //             trove.annualInterestRate, // _annualInterestRate
    //             type(uint256).max, //        _maxUpfrontFee
    //             address(0), //               _addManager
    //             address(0), //               _removeManager
    //             address(0) //                _receiver
    //         );

    //         vm.stopBroadcast();
    //     }
    // }
}
