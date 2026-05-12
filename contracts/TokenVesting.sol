// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenVesting
 */
contract TokenVesting is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        bool initialized;
        // beneficiary of tokens after they are released
        address beneficiary;
        // cliff period in seconds
        uint256 cliff;
        // start time of the vesting period
        uint256 start;
        // duration of the vesting period in seconds
        uint256 duration;
        // duration of a slice period for the vesting in seconds
        uint256 slicePeriodSeconds;
        // whether or not the vesting is revocable
        bool revocable;
        // total amount of tokens to be released at the end of the vesting
        uint256 amountTotal;
        // amount of tokens released
        uint256 released;
        // whether or not the vesting has been revoked
        bool revoked;
    }

    // address of the ERC20 token
    IERC20 private immutable _token;

    /**
     * @dev Array of all vesting schedule identifiers created in the contract.
     * Used to iterate and query schedules globally.
     */
    bytes32[] private vestingSchedulesIds;

    /**
     * @dev Mapping of vesting schedule identifiers to their detailed VestingSchedule struct.
     * Each vesting schedule contains parameters such as start, cliff, duration, etc.
     */
    mapping(bytes32 => VestingSchedule) private vestingSchedules;

    /**
     * @dev Total amount of tokens reserved across all active vesting schedules.
     * This value is used to determine how many tokens are still locked in the contract.
     */
    uint256 private vestingSchedulesTotalAmount;

    /**
     * @dev Mapping of beneficiary addresses to the number of vesting schedules they own.
     * Helps to fetch vesting schedule IDs by index for each holder.
     */
    mapping(address => uint256) private holdersVestingCount;

    /**
     * @dev Mapping of addresses that have the vesting creator role.
     * Addresses with this role can create vesting schedules for users.
     */
    mapping(address => bool) private _vestingCreators;

    /**
     * @notice Emitted when a vesting creator role is granted to an address.
     * @param account The address that was granted the role.
     */
    event VestingCreatorGranted(address indexed account);

    /**
     * @notice Emitted when a vesting creator role is revoked from an address.
     * @param account The address that had the role revoked.
     */
    event VestingCreatorRevoked(address indexed account);

    /**
     * @notice Emitted when vested tokens are released to a beneficiary.
     * @param user The address of the beneficiary receiving the tokens.
     * @param amount The amount of tokens released.
     * @param timestamp The block timestamp when the release occurred.
     */
    event Released(address indexed user, uint256 amount, uint256 timestamp);

    /**
     * @notice Emitted when a new vesting schedule is created for a beneficiary.
     * @param vestingId The unique identifier of the created vesting schedule.
     * @param timestamp The block timestamp when the schedule was created.
     * @param beneficiary The address of the beneficiary for whom the schedule was created.
     * @param holdersVestingCount The total number of vesting schedules currently owned by the beneficiary.
     */
    event VestingScheduled(
        bytes32 indexed vestingId,
        uint256 timestamp,
        address indexed beneficiary,
        uint256 holdersVestingCount
    );

    /**
     * @notice Emitted when a vesting schedule is revoked by the owner.
     * @param vestingScheduleId The identifier of the revoked vesting schedule.
     * @param beneficiary The address of the beneficiary whose vesting was revoked.
     * @param unreleased The amount of tokens that remained unreleased at the moment of revocation.
     */
    event Revoked(bytes32 indexed vestingScheduleId, address indexed beneficiary, uint256 unreleased);

    /**
     * @notice Emitted when the owner withdraws unallocated tokens from the contract.
     * @param amount The amount of tokens withdrawn by the owner.
     */
    event Withdrawn(uint256 amount);

    /**
     * @notice Emitted when the owner withdraws tokens of another ERC20 type (not the main vesting token).
     * @param tokenAddress The address of the ERC20 token being withdrawn.
     * @param receiver The address receiving the withdrawn tokens.
     * @param amount The amount of tokens withdrawn.
     */
    event OtherERC20Withdrawn(address indexed tokenAddress, address indexed receiver, uint256 amount);

    /**
     * @dev Reverts if the vesting schedule does not exist or has been revoked.
     */
    modifier onlyIfVestingScheduleNotRevoked(bytes32 vestingScheduleId) {
        require(vestingSchedules[vestingScheduleId].initialized, "TokenVesting: vesting schedule does not exist");
        require(!vestingSchedules[vestingScheduleId].revoked, "TokenVesting: vesting schedule has been revoked");
        _;
    }

    /**
     * @dev Reverts if the caller is neither the owner nor a vesting creator.
     */
    modifier onlyOwnerOrVestingCreator() {
        require(
            msg.sender == owner() || _vestingCreators[msg.sender],
            "TokenVesting: caller is not the owner or vesting creator"
        );
        _;
    }

    /**
     * @dev Creates a vesting contract.
     * @param token_ address of the ERC20 token contract
     */
    constructor(address token_) Ownable(msg.sender) {
        require(token_ != address(0), "TokenVesting: Incorrect token address");
        _token = IERC20(token_);
    }

    /**
     * @dev Returns the number of vesting schedules associated to a beneficiary.
     * @return the number of vesting schedules
     */
    function getVestingSchedulesCountByBeneficiary(address _beneficiary) external view returns (uint256) {
        return holdersVestingCount[_beneficiary];
    }

    /**
     * @dev Returns the vesting schedule id at the given index.
     * @return the vesting id
     */
    function getVestingIdAtIndex(uint256 index) external view returns (bytes32) {
        require(index < getVestingSchedulesCount(), "TokenVesting: index out of bounds");
        return vestingSchedulesIds[index];
    }

    /**
     * @notice Returns the vesting schedule information for a given holder and index.
     * @return the vesting schedule structure information
     */
    function getVestingScheduleByAddressAndIndex(
        address holder,
        uint256 index
    ) external view returns (VestingSchedule memory) {
        return getVestingSchedule(computeVestingScheduleIdForAddressAndIndex(holder, index));
    }

    /**
     * @notice Returns the total amount of vesting schedules.
     * @return the total amount of vesting schedules
     */
    function getVestingSchedulesTotalAmount() external view returns (uint256) {
        return vestingSchedulesTotalAmount;
    }

    /**
     * @dev Returns the address of the ERC20 token managed by the vesting contract.
     */
    function getToken() external view returns (address) {
        return address(_token);
    }

    /**
     * @notice Grants the vesting creator role to an address.
     * @param account The address to grant the role to.
     */
    function grantVestingCreatorRole(address account) external onlyOwner {
        require(account != address(0), "TokenVesting: zero address");
        require(!_vestingCreators[account], "TokenVesting: already a vesting creator");
        _vestingCreators[account] = true;
        emit VestingCreatorGranted(account);
    }

    /**
     * @notice Revokes the vesting creator role from an address.
     * @param account The address to revoke the role from.
     */
    function revokeVestingCreatorRole(address account) external onlyOwner {
        require(_vestingCreators[account], "TokenVesting: not a vesting creator");
        _vestingCreators[account] = false;
        emit VestingCreatorRevoked(account);
    }

    /**
     * @notice Checks whether an address has the vesting creator role.
     * @param account The address to check.
     * @return true if the address has the vesting creator role, false otherwise.
     */
    function isVestingCreator(address account) external view returns (bool) {
        return _vestingCreators[account];
    }

    /**
     * @notice Creates a new vesting schedule for a beneficiary.
     * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param _start start time of the vesting period
     * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
     * @param _duration duration in seconds of the period in which the tokens will vest
     * @param _slicePeriodSeconds duration of a slice period for the vesting in seconds
     * @param _revocable whether the vesting is revocable or not
     * @param _amount total amount of tokens to be released at the end of the vesting
     */
    function createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    ) external onlyOwnerOrVestingCreator {
        _createVestingSchedule(_beneficiary, _start, _cliff, _duration, _slicePeriodSeconds, _revocable, _amount);
    }

    /**
     * @dev Internal function to create a new vesting schedule for a beneficiary.
     * @param _beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param _start start time of the vesting period
     * @param _cliff duration in seconds of the cliff in which tokens will begin to vest
     * @param _duration duration in seconds of the period in which the tokens will vest
     * @param _slicePeriodSeconds duration of a slice period for the vesting in seconds
     * @param _revocable whether the vesting is revocable or not
     * @param _amount total amount of tokens to be released at the end of the vesting
     */
    function _createVestingSchedule(
        address _beneficiary,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool _revocable,
        uint256 _amount
    ) internal {
        require(
            _token.balanceOf(address(this)) - vestingSchedulesTotalAmount >= _amount,
            "TokenVesting: cannot create vesting schedule because not sufficient tokens"
        );
        require(_beneficiary != address(0x0), "TokenVesting: beneficiary address should be non-zero");
        require(_duration > 0, "TokenVesting: duration must be > 0");
        require(_amount > 0, "TokenVesting: amount must be > 0");
        require(_slicePeriodSeconds >= 1, "TokenVesting: slicePeriodSeconds must be >= 1");
        require(_duration >= _cliff, "TokenVesting: no vesting possible with cliff duration");

        bytes32 vestingScheduleId = computeVestingScheduleIdForAddressAndIndex(
            _beneficiary,
            holdersVestingCount[_beneficiary]
        );
        uint256 cliff = _start + _cliff;
        vestingSchedules[vestingScheduleId] = VestingSchedule(
            true,
            _beneficiary,
            cliff,
            _start,
            _duration,
            _slicePeriodSeconds,
            _revocable,
            _amount,
            0,
            false
        );
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount + _amount;
        vestingSchedulesIds.push(vestingScheduleId);
        uint256 currentVestingCount = holdersVestingCount[_beneficiary];
        holdersVestingCount[_beneficiary] = currentVestingCount + 1;

        emit VestingScheduled(vestingScheduleId, block.timestamp, _beneficiary, holdersVestingCount[_beneficiary]);
    }

    /**
     * @notice Creates multiple vesting schedules in a single transaction.
     * @param _beneficiaries array of beneficiary addresses
     * @param _cliff array of cliff durations in seconds
     * @param _duration array of vesting durations in seconds
     * @param _slicePeriodSeconds array of slice period durations
     * @param _amounts array of total amounts to be vested
     */
    function createVestingSchedulesBatch(
        address[] calldata _beneficiaries,
        uint256[] calldata _amounts,
        uint256 _start,
        uint256 _cliff,
        uint256 _duration,
        uint256 _slicePeriodSeconds,
        bool isRevocable
    ) external onlyOwnerOrVestingCreator {
        require(_beneficiaries.length != 0, "TokenVesting: empty arrays");
        require(_beneficiaries.length == _amounts.length, "TokenVesting: arrays length mismatch");

        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            _createVestingSchedule(
                _beneficiaries[i],
                _start,
                _cliff,
                _duration,
                _slicePeriodSeconds,
                isRevocable,
                _amounts[i]
            );
        }
    }

    /**
     * @notice Revokes the vesting schedule for given identifier.
     * @param vestingScheduleId the vesting schedule identifier
     */
    function revoke(
        bytes32 vestingScheduleId
    ) external onlyOwnerOrVestingCreator onlyIfVestingScheduleNotRevoked(vestingScheduleId) {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        require(vestingSchedule.revocable == true, "TokenVesting: vesting is not revocable");
        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        if (vestedAmount > 0) {
            release(vestingScheduleId, vestedAmount);
        }
        uint256 unreleased = vestingSchedule.amountTotal - vestingSchedule.released;
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount - unreleased;
        vestingSchedule.revoked = true;

        emit Revoked(vestingScheduleId, vestingSchedule.beneficiary, unreleased);
    }

    /**
     * @notice Withdraw the specified amount if possible.
     * @param amount the amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant onlyOwnerOrVestingCreator {
        require(getWithdrawableAmount() >= amount, "TokenVesting: not enough withdrawable funds");
        _token.safeTransfer(owner(), amount);

        emit Withdrawn(amount);
    }

    /**
     * @notice Function to withdraw stuck ERC-20 tokens
     * @param tokenAddress token type to withdraw
     */
    function withdrawOtherTokens(address tokenAddress) external nonReentrant onlyOwner {
        require(tokenAddress != address(0x0), "TokenVesting: invalid token address");
        IERC20 tokenInterface = IERC20(tokenAddress);
        require(tokenInterface != _token, "TokenVesting: use withdraw for contract token");

        uint256 balance = tokenInterface.balanceOf(address(this));
        require(balance > 0, "TokenVesting: no funds to withdraw");

        tokenInterface.safeTransfer(owner(), balance);

        emit OtherERC20Withdrawn(tokenAddress, owner(), balance);
    }

    /**
     * @notice Release vested amount of tokens.
     * @param vestingScheduleId the vesting schedule identifier
     * @param amount the amount to release
     */
    function release(
        bytes32 vestingScheduleId,
        uint256 amount
    ) public nonReentrant onlyIfVestingScheduleNotRevoked(vestingScheduleId) {
        require(amount != 0, "TokenVesting: Amount can't be zero");

        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        bool isBeneficiary = msg.sender == vestingSchedule.beneficiary;
        bool isOwner = msg.sender == owner();
        require(isBeneficiary || isOwner, "TokenVesting: only beneficiary and owner can release vested tokens");

        uint256 vestedAmount = _computeReleasableAmount(vestingSchedule);
        require(vestedAmount >= amount, "TokenVesting: cannot release tokens, not enough vested tokens");

        vestingSchedule.released = vestingSchedule.released + amount;

        address beneficiary = vestingSchedule.beneficiary;
        vestingSchedulesTotalAmount = vestingSchedulesTotalAmount - amount;

        _token.safeTransfer(beneficiary, amount);

        emit Released(beneficiary, amount, block.timestamp);
    }

    /**
     * @dev Returns the number of vesting schedules managed by this contract.
     * @return the number of vesting schedules
     */
    function getVestingSchedulesCount() public view returns (uint256) {
        return vestingSchedulesIds.length;
    }

    /**
     * @notice Computes the vested amount of tokens for the given vesting schedule identifier.
     * @return the vested amount
     */
    function computeReleasableAmount(
        bytes32 vestingScheduleId
    ) external view onlyIfVestingScheduleNotRevoked(vestingScheduleId) returns (uint256) {
        VestingSchedule storage vestingSchedule = vestingSchedules[vestingScheduleId];
        return _computeReleasableAmount(vestingSchedule);
    }

    /**
     * @notice Returns the vesting schedule information for a given identifier.
     * @return the vesting schedule structure information
     */
    function getVestingSchedule(bytes32 vestingScheduleId) public view returns (VestingSchedule memory) {
        return vestingSchedules[vestingScheduleId];
    }

    /**
     * @dev Returns the amount of tokens that can be withdrawn by the owner.
     * @return the amount of tokens
     */
    function getWithdrawableAmount() public view returns (uint256) {
        return _token.balanceOf(address(this)) - vestingSchedulesTotalAmount;
    }

    /**
     * @dev Computes the next vesting schedule identifier for a given holder address.
     */
    function computeNextVestingScheduleIdForHolder(address holder) external view returns (bytes32) {
        return computeVestingScheduleIdForAddressAndIndex(holder, holdersVestingCount[holder]);
    }

    /**
     * @dev Returns the last vesting schedule for a given holder address.
     */
    function getLastVestingScheduleForHolder(address holder) external view returns (VestingSchedule memory) {
        require(holdersVestingCount[holder] != 0, "TokenVesting: holder has no schedules");

        return vestingSchedules[computeVestingScheduleIdForAddressAndIndex(holder, holdersVestingCount[holder] - 1)];
    }

    /**
     * @notice Returns all vesting schedules for a holder in a single call.
     * @param holder The address to query vestings for.
     * @return scheduleIds Array of vesting schedule identifiers.
     * @return schedules Array of VestingSchedule structs.
     */
    function getAllVestingSchedulesForHolder(
        address holder
    ) external view returns (bytes32[] memory scheduleIds, VestingSchedule[] memory schedules) {
        uint256 count = holdersVestingCount[holder];
        scheduleIds = new bytes32[](count);
        schedules = new VestingSchedule[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 id = computeVestingScheduleIdForAddressAndIndex(holder, i);
            scheduleIds[i] = id;
            schedules[i] = vestingSchedules[id];
        }
    }

    /**
     * @notice Returns all vesting schedules for a holder together with releasable amounts.
     *         Single-call convenience method for frontend/indexer use.
     * @param holder The address to query vestings for.
     * @return scheduleIds Array of vesting schedule identifiers.
     * @return schedules Array of VestingSchedule structs.
     * @return releasableAmounts Array of currently releasable token amounts per schedule.
     */
    function getFullVestingInfoForHolder(
        address holder
    )
        external
        view
        returns (bytes32[] memory scheduleIds, VestingSchedule[] memory schedules, uint256[] memory releasableAmounts)
    {
        uint256 count = holdersVestingCount[holder];
        scheduleIds = new bytes32[](count);
        schedules = new VestingSchedule[](count);
        releasableAmounts = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 id = computeVestingScheduleIdForAddressAndIndex(holder, i);
            scheduleIds[i] = id;
            schedules[i] = vestingSchedules[id];
            if (schedules[i].initialized && !schedules[i].revoked) {
                releasableAmounts[i] = _computeReleasableAmount(schedules[i]);
            }
        }
    }

    /**
     * @dev Computes the vesting schedule identifier for an address and an index.
     */
    function computeVestingScheduleIdForAddressAndIndex(address holder, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(holder, index));
    }

    /**
     * @dev Returns the current time. Can be overridden in tests.
     * @return the current timestamp
     */
    function getCurrentTime() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    /**
     * @dev Computes the releasable amount of tokens for a vesting schedule.
     * @return the amount of releasable tokens
     */
    function _computeReleasableAmount(VestingSchedule memory vestingSchedule) internal view returns (uint256) {
        uint256 currentTime = getCurrentTime();
        if ((currentTime < vestingSchedule.cliff) || vestingSchedule.revoked == true) {
            return 0;
        } else if (currentTime >= vestingSchedule.start + vestingSchedule.duration) {
            return vestingSchedule.amountTotal - vestingSchedule.released;
        } else {
            // Vesting starts from cliff and continues for (duration - cliff) period
            uint256 timeFromCliff = currentTime - vestingSchedule.cliff;
            uint256 secondsPerSlice = vestingSchedule.slicePeriodSeconds;
            uint256 vestedSlicePeriods = timeFromCliff / secondsPerSlice;
            uint256 vestedSeconds = vestedSlicePeriods * secondsPerSlice;

            // Calculate vesting period: duration minus cliff period
            uint256 vestingPeriod = vestingSchedule.duration - (vestingSchedule.cliff - vestingSchedule.start);

            uint256 vestedAmount = (vestingSchedule.amountTotal * vestedSeconds) / vestingPeriod;

            vestedAmount = vestedAmount - vestingSchedule.released;
            return vestedAmount;
        }
    }
}
