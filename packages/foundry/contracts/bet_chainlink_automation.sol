// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@chainlink/contracts/src/v0.8/AutomationCompatible.sol";

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Wagerly is AutomationCompatible {
    address private constant FEE_ADDRESS = 0x9b63FA365019Dd7bdF8cBED2823480F808391970;
    uint256 private nextBetId = 1;
    uint256 private constant DISTRIBUTION_DELAY = 5 minutes;

    struct Bet {
        address bettor;
        uint256 amount;
    }

    struct BetInstance {
        uint256 id;
        string title;
        string[] options;
        uint256[] totalAmounts;
        uint256 minimumBetAmount;
        address tokenAddress;
        mapping(address => Bet[]) bets;
        address[] bettors;
        address creator;
        bool isClosed;
        bool isResolved;
        uint8 winningOption;
        uint256 distributionTime; // Tiempo en el que se debe distribuir el premio
    }

    mapping(uint256 => BetInstance) private betInstances;

    event BetInstanceCreated(address creator, uint256 indexed betId, string title, string[] options, uint256 minimumBetAmount, address tokenAddress);
    event BetPlaced(uint256 indexed betId, address indexed bettor, uint256 amount, uint8 option);
    event BettingClosed(uint256 indexed betId);
    event BettingResolved(uint256 indexed betId, uint8 winningOption);
    event BetCancelled(uint256 indexed betId);
    event WinningsDistributed(uint256 indexed betId);

    modifier onlyCreator(uint256 _betId) {
        require(msg.sender == betInstances[_betId].creator, "Not authorized");
        _;
    }

    function createBetInstance(
        string calldata _title,
        uint8 _numOptions,
        string[] calldata _optionNames,
        uint256 _minimumBetAmount,
        address _tokenAddress
    ) external {
        require(_numOptions >= 2 && _numOptions <= 5, "Invalid number of options");
        require(_optionNames.length == _numOptions, "Option names length mismatch");

        uint256 betId = nextBetId; 
        nextBetId++; 

        BetInstance storage newInstance = betInstances[betId];
        newInstance.id = betId;
        newInstance.title = _title;
        newInstance.minimumBetAmount = _minimumBetAmount;
        newInstance.creator = msg.sender;
        newInstance.tokenAddress = _tokenAddress;
        newInstance.totalAmounts = new uint256[](_numOptions);

        for (uint8 i = 0; i < _numOptions; i++) {
            newInstance.options.push(_optionNames[i]);
        }

        emit BetInstanceCreated(msg.sender, betId, _title, _optionNames, _minimumBetAmount, _tokenAddress);
    }

    function placeBet(uint256 _betId, uint256 _amount, uint8 _option) external {
        BetInstance storage betInstance = betInstances[_betId];
        require(!betInstance.isClosed, "Betting is closed");
        require(_amount >= betInstance.minimumBetAmount, "Bet amount is less than minimum");
        require(_option >= 1 && _option <= betInstance.options.length, "Invalid option");

        IERC20 token = IERC20(betInstance.tokenAddress);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        betInstance.totalAmounts[_option - 1] += _amount;
        betInstance.bets[msg.sender].push(Bet(msg.sender, _amount));
        betInstance.bettors.push(msg.sender);

        emit BetPlaced(_betId, msg.sender, _amount, _option);
    }

    function closeBetting(uint256 _betId) external onlyCreator(_betId) {
        BetInstance storage betInstance = betInstances[_betId];
        require(!betInstance.isClosed, "Betting is already closed");
        betInstance.isClosed = true;
        emit BettingClosed(_betId);
    }

    function distributeWinnings(uint256 _betId, uint8 _winningOption) external onlyCreator(_betId) {
        BetInstance storage betInstance = betInstances[_betId];
        require(betInstance.isClosed && !betInstance.isResolved, "Betting must be closed and not resolved");
        require(_winningOption >= 1 && _winningOption <= betInstance.options.length, "Invalid winning option");

        betInstance.isResolved = true;
        betInstance.winningOption = _winningOption;
        betInstance.distributionTime = block.timestamp + DISTRIBUTION_DELAY;

        emit BettingResolved(_betId, _winningOption);
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        for (uint256 betId = 1; betId < nextBetId; betId++) {
            BetInstance storage betInstance = betInstances[betId];
            if (betInstance.isResolved && !betInstance.isClosed && block.timestamp >= betInstance.distributionTime) {
                return (true, abi.encode(betId));
            }
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        (uint256 betId) = abi.decode(performData, (uint256));
        BetInstance storage betInstance = betInstances[betId];
        if (betInstance.isResolved && !betInstance.isClosed && block.timestamp >= betInstance.distributionTime) {
            _distributeWinnings(betId);
        }
    }

    function _distributeWinnings(uint256 _betId) internal {
        BetInstance storage betInstance = betInstances[_betId];

        IERC20 token = IERC20(betInstance.tokenAddress);

        uint256 totalAmountToDistribute = 0;
        for (uint8 i = 0; i < betInstance.totalAmounts.length; i++) {
            totalAmountToDistribute += betInstance.totalAmounts[i];
        }
        uint256 totalAmountWinningOption = betInstance.totalAmounts[betInstance.winningOption - 1];

        uint256 fee = totalAmountToDistribute / 100;
        uint256 creatorFee = fee;
        uint256 remainingAmount = totalAmountToDistribute - fee - creatorFee;

        require(token.transfer(FEE_ADDRESS, fee), "Fee transfer failed");
        require(token.transfer(betInstance.creator, creatorFee), "Creator fee transfer failed");

        for (uint256 i = 0; i < betInstance.bettors.length; i++) {
            address bettor = betInstance.bettors[i];
            Bet[] storage bets = betInstance.bets[bettor];
            for (uint8 j = 0; j < bets.length; j++) {
                uint256 amountToTransfer = (bets[j].amount * remainingAmount) / totalAmountWinningOption;
                require(token.transfer(bettor, amountToTransfer), "Winner transfer failed");
            }
        }

        emit WinningsDistributed(_betId);
    }

    function cancelBet(uint256 _betId) external onlyCreator(_betId) {
        BetInstance storage betInstance = betInstances[_betId];
        require(!betInstance.isResolved, "Betting already resolved");

        IERC20 token = IERC20(betInstance.tokenAddress);

        uint256 totalAmountToDistribute = 0;
        for (uint8 i = 0; i < betInstance.totalAmounts.length; i++) {
            totalAmountToDistribute += betInstance.totalAmounts[i];
        }

        uint256 fee = totalAmountToDistribute / 100;
        uint256 creatorFee = fee;
        uint256 remainingAmount = totalAmountToDistribute - fee - creatorFee;

        require(token.transfer(FEE_ADDRESS, fee), "Fee transfer failed");
        require(token.transfer(betInstance.creator, creatorFee), "Creator fee transfer failed");

        for (uint256 i = 0; i < betInstance.bettors.length; i++) {
            address bettor = betInstance.bettors[i];
            Bet[] storage bets = betInstance.bets[bettor];
            for (uint8 j = 0; j < bets.length; j++) {
                uint256 betAmount = bets[j].amount;
                uint256 amountToTransfer = (betAmount * remainingAmount) / totalAmountToDistribute;
                require(token.transfer(bettor, amountToTransfer), "Bettor transfer failed");
            }
        }

        emit BetCancelled(_betId);
    }

    function getBetInfo(uint256 _betId) external view returns (
        address creator,
        string memory title,
        string[] memory options,
        bool isClosed,
        bool isResolved,
        uint256 totalAmountBet,
        uint256[] memory totalAmounts,
        address tokenAddress,
        uint8 winningOption,
        uint256 distributionTime
    ) {
        BetInstance storage betInstance = betInstances[_betId];
        creator = betInstance.creator;
        title = betInstance.title;
        options = betInstance.options;
        isClosed = betInstance.isClosed;
        isResolved = betInstance.isResolved;
        totalAmountBet = 0;
        for (uint8 i = 0; i < betInstance.totalAmounts.length; i++) {
            totalAmountBet += betInstance.totalAmounts[i];
        }
        totalAmounts = betInstance.totalAmounts;
        tokenAddress = betInstance.tokenAddress;
        winningOption = betInstance.winningOption;
        distributionTime = betInstance.distributionTime;
    }
}
