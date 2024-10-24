// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@oz-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@oz-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

import {Vesting, Schedule, IVestingToken} from "./IVestingToken.sol";

/**
 * @title Контракт share-токена (вестинг-токен)
 * @notice Отвечает за логику блокировки/разблокировки средств
 * @dev Код предоставлен исключительно в ознакомительных целях и не протестирован
 * Из контракта убрано все лишнее, включая некоторые проверки, геттеры/сеттеры и события
 */
contract VestingToken is IVestingToken, Initializable, ERC20Upgradeable {
    using SafeERC20 for IERC20;

    uint256 public immutable basisPoints;

    address private _minter;
    address private _vestingManager;
    IERC20 private _baseToken;
    Vesting private _vesting;
    uint256 private _initialLockedSupply;

    constructor(uint256 _basisPoints) {
        basisPoints = _basisPoints;
        _disableInitializers();
    }

    mapping(address => uint256) private _initialLocked;
    mapping(address => uint256) private _released;

    // region - Events
    /////////////////////
    //      Events     //
    /////////////////////

    event MintTokens(address indexed token, address indexed to, uint256 tokenCount);
    // endregion

    // region - Errors

    /////////////////////
    //      Errors     //
    /////////////////////

    error OnlyMinter();
    error MinterNotSet();
    error OnlyVestingManager();
    error NotEnoughTokensToClaim();
    error StartTimeAlreadyElapsed();
    error CliffBeforeStartTime();
    error IncorrectSchedulePortions();
    error IncorrectScheduleTime(uint256 incorrectTime);
    error TransfersNotAllowed();
    error MintingAfterCliffIsForbidden();
    error PercentError();

    // endregion

    // region - Modifiers

    modifier onlyMinter() {
        if (msg.sender != _minter) {
            revert OnlyMinter();
        }

        _;
    }

    modifier onlyVestingManager() {
        if (msg.sender != _vestingManager) {
            revert OnlyVestingManager();
        }

        _;
    }

    // endregion

    // region - Initialize

    /**
     * @notice Так как это прокси, нужно выполнить инициализацию
     * @dev Создается и инициализируется только контрактом VestingManager
     */
    function initialize(string calldata _name, string calldata _symbol, address minter, address baseToken)
        public
        initializer
    {
        if (minter == address(0)) revert MinterNotSet();

        __ERC20_init(_name, _symbol);

        _minter = minter;
        _baseToken = IERC20(baseToken);
        _vestingManager = msg.sender;
    }

    // endregion

    function getMinter() public view returns (address) {
        return _minter;
    }

    // region - Set vesting schedule

    /**
     * @notice Установка расписания также выполняется контрактом VestingManager
     * @dev Здесь важно проверить что расписание было передано корректное
     */
    function setVestingSchedule(uint256 startTime, uint256 cliff, uint8 initialUnlock, Schedule[] calldata schedule)
        external
        onlyVestingManager
    {
        if (initialUnlock >= 101) {
            revert PercentError();
        }
        uint256 scheduleLength = schedule.length;

        _checkVestingSchedule(startTime, cliff, schedule, scheduleLength);

        _vesting.startTime = startTime;
        _vesting.cliff = cliff;
        _vesting.initialUnlock = initialUnlock;

        for (uint256 i = 0; i < scheduleLength;) {
            _vesting.schedule.push(schedule[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _checkVestingSchedule(
        uint256 startTime,
        uint256 cliff,
        Schedule[] calldata schedule,
        uint256 scheduleLength
    ) private view {
        if (startTime < block.timestamp) {
            revert StartTimeAlreadyElapsed();
        }

        if (startTime > cliff) {
            revert CliffBeforeStartTime();
        }

        uint256 totalPercent;

        for (uint256 i = 0; i < scheduleLength;) {
            totalPercent += schedule[i].portion;

            bool isEndTimeOutOfOrder = (i != 0) && schedule[i - 1].endTime >= schedule[i].endTime;

            if (cliff >= schedule[i].endTime || isEndTimeOutOfOrder) {
                revert IncorrectScheduleTime(schedule[i].endTime);
            }

            unchecked {
                ++i;
            }
        }

        if (totalPercent != basisPoints) {
            revert IncorrectSchedulePortions();
        }
    }

    // endregion

    // region - Mint

    /**
     * @notice Списываем токен который будем блокировать и минтим share-токен
     */
    function mint(address to, uint256 amount) external onlyMinter {
        if (block.timestamp > _vesting.cliff) {
            revert MintingAfterCliffIsForbidden();
        }
        _initialLocked[to] = _initialLocked[to] + amount;
        _initialLockedSupply = _initialLockedSupply + amount;
        address thisAddress = address(this);
        emit MintTokens(thisAddress, to, amount);
        _mint(to, amount);
        _baseToken.safeTransferFrom(msg.sender, thisAddress, amount);
    }

    // endregion

    // region - Claim

    /**
     * @notice Сжигаем share-токен и переводим бенефициару разблокированные базовые токены
     */
    function claim() external {
        uint256 releasable = availableBalanceOf(msg.sender);
        if (releasable <= 0) {
            revert NotEnoughTokensToClaim();
        }

        _released[msg.sender] = _released[msg.sender] + releasable;

        _burn(msg.sender, releasable);
        _baseToken.safeTransfer(msg.sender, releasable);
    }

    // endregion

    // region - Vesting getters

    function getVestingSchedule() public view returns (Vesting memory) {
        return _vesting;
    }

    function unlockedSupply() external view returns (uint256) {
        return _totalUnlocked();
    }

    function lockedSupply() external view returns (uint256) {
        return _initialLockedSupply - _totalUnlocked();
    }

    function availableBalanceOf(address account) public view returns (uint256 releasable) {
        releasable = _unlockedOf(account) - _released[account];
    }

    // endregion

    // region - Private functions

    function _unlockedOf(address account) private view returns (uint256) {
        return _computeUnlocked(_initialLocked[account], block.timestamp);
    }

    function _totalUnlocked() private view returns (uint256) {
        return _computeUnlocked(_initialLockedSupply, block.timestamp);
    }

    /**
     * @notice Основная функция для расчета разблокированных токенов
     * @dev Проверяется сколько прошло полных периодов и сколько времени прошло
     * после последнего полного периода.
     */
    function _computeUnlocked(uint256 lockedTokens, uint256 time) private view returns (uint256 unlockedTokens) {
        if (time < _vesting.cliff) {
            return 0;
        }

        uint256 currentPeriodStart = _vesting.cliff;
        Schedule[] memory schedule = _vesting.schedule;
        uint256 scheduleLength = schedule.length;
        //initial unlock tokens
        uint256 initialUnlockedTokens = lockedTokens * _vesting.initialUnlock / 100;
        uint256 lockedTokensVesting = lockedTokens - initialUnlockedTokens;
        unlockedTokens = initialUnlockedTokens;
        //---
        for (uint256 i = 0; i < scheduleLength;) {
            Schedule memory currentPeriod = schedule[i];
            uint256 currentPeriodEnd = currentPeriod.endTime;
            uint256 currentPeriodPortion = currentPeriod.portion;

            if (time < currentPeriodEnd) {
                uint256 elapsedPeriodTime = time - currentPeriodStart;
                uint256 periodDuration = currentPeriodEnd - currentPeriodStart;

                unlockedTokens +=
                    (lockedTokensVesting * elapsedPeriodTime * currentPeriodPortion) / (periodDuration * basisPoints);
                break;
            } else {
                unlockedTokens += (lockedTokensVesting * currentPeriodPortion) / basisPoints;
                currentPeriodStart = currentPeriodEnd;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Трансферить токены нельзя, только минтить и сжигать
     */
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0) && to != address(0)) {
            revert TransfersNotAllowed();
        }
        super._update(from, to, amount);
    }
    // endregion
}
