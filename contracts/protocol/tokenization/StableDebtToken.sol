// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {MathUtils} from '../libraries/math/MathUtils.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {IInitializableDebtToken} from '../../interfaces/IInitializableDebtToken.sol';
import {IStableDebtToken} from '../../interfaces/IStableDebtToken.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {DebtTokenBase} from './base/DebtTokenBase.sol';
import {IncentivizedERC20} from './base/IncentivizedERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title StableDebtToken
 * @author Aave
 * @notice Implements a stable debt token to track the borrowing positions of users
 * at stable rate mode
 **/
contract StableDebtToken is IStableDebtToken, DebtTokenBase {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  uint256 public constant DEBT_TOKEN_REVISION = 0x2;

  // Map of users address and the timestamp of their last update (userAddress => lastUpdateTimestamp)
  mapping(address => uint40) internal _timestamps;

  uint128 internal _avgStableRate;

  // Timestamp of the last update of the total supply
  uint40 internal _totalSupplyTimestamp;

  /**
   * @dev Constructor.
   * @param pool The address of the Pool contract
   */
  constructor(IPool pool) DebtTokenBase(pool) {
    // Intentionally left blank
  }

  /// @inheritdoc IInitializableDebtToken
  function initialize(
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 debtTokenDecimals,
    string memory debtTokenName,
    string memory debtTokenSymbol,
    bytes calldata params
  ) external override initializer {
    _setName(debtTokenName);
    _setSymbol(debtTokenSymbol);
    _setDecimals(debtTokenDecimals);

    _underlyingAsset = underlyingAsset;
    _incentivesController = incentivesController;

    _domainSeparator = _calculateDomainSeparator();

    emit Initialized(
      underlyingAsset,
      address(POOL),
      address(incentivesController),
      debtTokenDecimals,
      debtTokenName,
      debtTokenSymbol,
      params
    );
  }

  /// @inheritdoc VersionedInitializable
  function getRevision() internal pure virtual override returns (uint256) {
    return DEBT_TOKEN_REVISION;
  }

  /// @inheritdoc IStableDebtToken
  function getAverageStableRate() external view virtual override returns (uint256) {
    return _avgStableRate;
  }

  /// @inheritdoc IStableDebtToken
  function getUserLastUpdated(address user) external view virtual override returns (uint40) {
    return _timestamps[user];
  }

  /// @inheritdoc IStableDebtToken
  function getUserStableRate(address user) external view virtual override returns (uint256) {
    return _userState[user].additionalData;
  }

  /// @inheritdoc IERC20
  function balanceOf(address account) public view virtual override returns (uint256) {
    uint256 accountBalance = super.balanceOf(account);
    uint256 stableRate = _userState[account].additionalData;
    if (accountBalance == 0) {
      return 0;
    }
    uint256 cumulatedInterest = MathUtils.calculateCompoundedInterest(
      stableRate,
      _timestamps[account]
    );
    return accountBalance.rayMul(cumulatedInterest);
  }

  struct MintLocalVars {
    uint256 previousSupply;
    uint256 nextSupply;
    uint256 amountInRay;
    uint256 currentStableRate;
    uint256 nextStableRate;
    uint256 currentAvgStableRate;
  }

  /// @inheritdoc IStableDebtToken
  function mint(
    address user,
    address onBehalfOf,
    uint256 amount,
    uint256 rate
  )
    external
    override
    onlyPool
    returns (
      bool,
      uint256,
      uint256
    )
  {
    MintLocalVars memory vars;

    if (user != onBehalfOf) {
      _decreaseBorrowAllowance(onBehalfOf, user, amount);
    }

    (, uint256 currentBalance, uint256 balanceIncrease) = _calculateBalanceIncrease(onBehalfOf);

    vars.previousSupply = totalSupply();
    vars.currentAvgStableRate = _avgStableRate;
    vars.nextSupply = _totalSupply = vars.previousSupply + amount;

    vars.amountInRay = amount.wadToRay();

    vars.currentStableRate = _userState[onBehalfOf].additionalData;
    vars.nextStableRate = (vars.currentStableRate.rayMul(currentBalance.wadToRay()) +
      vars.amountInRay.rayMul(rate)).rayDiv((currentBalance + amount).wadToRay());

    _userState[onBehalfOf].additionalData = vars.nextStableRate.toUint128();

    //solium-disable-next-line
    _totalSupplyTimestamp = _timestamps[onBehalfOf] = uint40(block.timestamp);

    // Calculates the updated average stable rate
    vars.currentAvgStableRate = _avgStableRate = (
      (vars.currentAvgStableRate.rayMul(vars.previousSupply.wadToRay()) +
        rate.rayMul(vars.amountInRay)).rayDiv(vars.nextSupply.wadToRay())
    ).toUint128();

    uint256 amountToMint = amount + balanceIncrease;
    _mint(onBehalfOf, amountToMint, vars.previousSupply);

    emit Transfer(address(0), onBehalfOf, amountToMint);
    emit Mint(
      user,
      onBehalfOf,
      amountToMint,
      currentBalance,
      balanceIncrease,
      vars.nextStableRate,
      vars.currentAvgStableRate,
      vars.nextSupply
    );

    return (currentBalance == 0, vars.nextSupply, vars.currentAvgStableRate);
  }

  /// @inheritdoc IStableDebtToken
  function burn(address user, uint256 amount)
    external
    override
    onlyPool
    returns (uint256, uint256)
  {
    (, uint256 currentBalance, uint256 balanceIncrease) = _calculateBalanceIncrease(user);

    uint256 previousSupply = totalSupply();
    uint256 nextAvgStableRate = 0;
    uint256 nextSupply = 0;
    uint256 userStableRate = _userState[user].additionalData;

    // Since the total supply and each single user debt accrue separately,
    // there might be accumulation errors so that the last borrower repaying
    // might actually try to repay more than the available debt supply.
    // In this case we simply set the total supply and the avg stable rate to 0
    if (previousSupply <= amount) {
      _avgStableRate = 0;
      _totalSupply = 0;
    } else {
      nextSupply = _totalSupply = previousSupply - amount;
      uint256 firstTerm = uint256(_avgStableRate).rayMul(previousSupply.wadToRay());
      uint256 secondTerm = userStableRate.rayMul(amount.wadToRay());

      // For the same reason described above, when the last user is repaying it might
      // happen that user rate * user balance > avg rate * total supply. In that case,
      // we simply set the avg rate to 0
      if (secondTerm >= firstTerm) {
        nextAvgStableRate = _totalSupply = _avgStableRate = 0;
      } else {
        nextAvgStableRate = _avgStableRate = (
          (firstTerm - secondTerm).rayDiv(nextSupply.wadToRay())
        ).toUint128();
      }
    }

    if (amount == currentBalance) {
      _userState[user].additionalData = 0;
      _timestamps[user] = 0;
    } else {
      //solium-disable-next-line
      _timestamps[user] = uint40(block.timestamp);
    }
    //solium-disable-next-line
    _totalSupplyTimestamp = uint40(block.timestamp);

    if (balanceIncrease > amount) {
      uint256 amountToMint = balanceIncrease - amount;
      _mint(user, amountToMint, previousSupply);
      emit Transfer(address(0), user, amountToMint);
      emit Mint(
        user,
        user,
        amountToMint,
        currentBalance,
        balanceIncrease,
        userStableRate,
        nextAvgStableRate,
        nextSupply
      );
    } else {
      uint256 amountToBurn = amount - balanceIncrease;
      _burn(user, amountToBurn, previousSupply);
      emit Transfer(user, address(0), amountToBurn);
      emit Burn(user, amountToBurn, currentBalance, balanceIncrease, nextAvgStableRate, nextSupply);
    }

    return (nextSupply, nextAvgStableRate);
  }

  /**
   * @notice Calculates the increase in balance since the last user interaction
   * @param user The address of the user for which the interest is being accumulated
   * @return The previous principal balance
   * @return The new principal balance
   * @return The balance increase
   **/
  function _calculateBalanceIncrease(address user)
    internal
    view
    returns (
      uint256,
      uint256,
      uint256
    )
  {
    uint256 previousPrincipalBalance = super.balanceOf(user);

    if (previousPrincipalBalance == 0) {
      return (0, 0, 0);
    }

    uint256 newPrincipalBalance = balanceOf(user);

    return (
      previousPrincipalBalance,
      newPrincipalBalance,
      newPrincipalBalance - previousPrincipalBalance
    );
  }

  /// @inheritdoc IStableDebtToken
  function getSupplyData()
    external
    view
    override
    returns (
      uint256,
      uint256,
      uint256,
      uint40
    )
  {
    uint256 avgRate = _avgStableRate;
    return (super.totalSupply(), _calcTotalSupply(avgRate), avgRate, _totalSupplyTimestamp);
  }

  /// @inheritdoc IStableDebtToken
  function getTotalSupplyAndAvgRate() external view override returns (uint256, uint256) {
    uint256 avgRate = _avgStableRate;
    return (_calcTotalSupply(avgRate), avgRate);
  }

  /// @inheritdoc IERC20
  function totalSupply() public view override returns (uint256) {
    return _calcTotalSupply(_avgStableRate);
  }

  /// @inheritdoc IStableDebtToken
  function getTotalSupplyLastUpdated() external view override returns (uint40) {
    return _totalSupplyTimestamp;
  }

  /// @inheritdoc IStableDebtToken
  function principalBalanceOf(address user) external view virtual override returns (uint256) {
    return super.balanceOf(user);
  }

  /// @inheritdoc IStableDebtToken
  function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
    return _underlyingAsset;
  }

  /**
   * @notice Calculates the total supply
   * @param avgRate The average rate at which the total supply increases
   * @return The debt balance of the user since the last burn/mint action
   **/
  function _calcTotalSupply(uint256 avgRate) internal view virtual returns (uint256) {
    uint256 principalSupply = super.totalSupply();

    if (principalSupply == 0) {
      return 0;
    }

    uint256 cumulatedInterest = MathUtils.calculateCompoundedInterest(
      avgRate,
      _totalSupplyTimestamp
    );

    return principalSupply.rayMul(cumulatedInterest);
  }

  /**
   * @notice Mints stable debt tokens to a user
   * @param account The account receiving the debt tokens
   * @param amount The amount being minted
   * @param oldTotalSupply The total supply before the minting event
   **/
  function _mint(
    address account,
    uint256 amount,
    uint256 oldTotalSupply
  ) internal {
    uint128 castAmount = amount.toUint128();
    uint128 oldAccountBalance = _userState[account].balance;
    _userState[account].balance = oldAccountBalance + castAmount;

    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(account, oldTotalSupply, oldAccountBalance);
    }
  }

  /**
   * @notice Burns stable debt tokens of a user
   * @param account The user getting his debt burned
   * @param amount The amount being burned
   * @param oldTotalSupply The total supply before the burning event
   **/
  function _burn(
    address account,
    uint256 amount,
    uint256 oldTotalSupply
  ) internal {
    uint128 castAmount = amount.toUint128();
    uint128 oldAccountBalance = _userState[account].balance;
    _userState[account].balance = oldAccountBalance - castAmount;

    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(account, oldTotalSupply, oldAccountBalance);
    }
  }
}
