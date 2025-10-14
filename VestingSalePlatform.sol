// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Payment currency enum
enum PaymentCurrency {
	NATIVE, // ETH
	USDT,
	USD1
}

/// @notice Purchase info shape required by the spec (referenced by child and factory)
struct PurchaseInfo {
	address saleAddress; // which sale
	uint256 amount;      // total bought tokens (1eTokenDecimals)
	uint256 claimed;     // already claimed (1eTokenDecimals)
	bool participated;   // used for buyersCount accounting
}

/// @title Vesting Sale Platform (Factory)
/// @notice A factory that deploys sale contracts which sell an ERC20 token for ETH or a whitelisted
///         stable (USDT / USD1) with linear (daily) vesting starting when the sale ends.
contract VestingSalePlatform is Ownable(msg.sender), ReentrancyGuard {
	using SafeERC20 for IERC20;

	// -----------------------
	// Platform configuration
	// -----------------------

	/// @notice 1% platform fee taken from total proceeds on withdrawal (100 = 1%)
	uint256 public constant FEE_BPS = 100; // 100 bps = 1%
	uint256 public constant BPS_DENOM = 10_000;

	/// @notice Fee to create a sale (in wei) - can be updated by owner
	uint256 public saleCreationFee = 0.002 ether;

	/// @notice Default sale duration applied at creation (can be updated for future sales)
	uint256 public defaultSaleDuration = 180 days; // 6 months

	/// @notice Treasury where platform fee and creation fee are sent
	address public treasury;

	/// @notice Address whose signature authorizes purchases (off-chain pricing/quote)
	address public quoteSigner;

	/// @notice Whitelisted payment tokens
	address public usdt; // optional, can be zero if unused
	address public usd1; // optional, can be zero if unused

	/// @notice Basic sale metadata kept in the factory for discovery and listing
	struct Sale {
		address saleAddress;    // deployed sale contract address
		address projectOwner;   // seller address
		address token;          // token being sold
		PaymentCurrency currency; // payment currency type
		uint256 startTime;      // block.timestamp at creation
		uint256 endTime;        // startTime + duration unless ends early
		uint256 vestingDuration;// seconds
		uint256 hardCap;      // hard cap in token units (1eTokenDecimals)
		uint256 discount;       // discount percentage (basis points, e.g., 500 = 5%)
		uint256 soldTokens;     // updated by child
		uint256 buyersCount;    // updated by child
		bool endedEarly;        // true if finalized due to hard cap reached
	}

	/// @notice Emitted when a new sale is created
	event SaleCreated(
		uint256 indexed saleId,
		address indexed saleAddress,
		address indexed projectOwner,
		address token,
		PaymentCurrency currency,
		uint256 hardCap,
		uint256 discount,
		uint256 startTime,
		uint256 endTime,
		uint256 vestingDuration
	);

	/// @notice Emitted when treasury updated
	event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

	/// @notice Emitted when default sale duration updated
	event DefaultSaleDurationChanged(uint256 oldDuration, uint256 newDuration);

	/// @notice Emitted when sale creation fee updated
	event SaleCreationFeeChanged(uint256 oldFee, uint256 newFee);

	/// @notice Emitted when quote signer updated
	event QuoteSignerChanged(address indexed oldSigner, address indexed newSigner);

	/// @notice Emitted on purchase (relayed by child)
	event Purchased(uint256 indexed saleId, address indexed buyer, uint256 paymentAmount, uint256 tokenAmount);

	/// @notice Emitted when buyer claims (relayed by child)
	event Claimed(uint256 indexed saleId, address indexed buyer, uint256 claimedAmount);

	/// @notice Emitted when project withdraws proceeds
	event ProceedsWithdrawn(uint256 indexed saleId, address indexed projectOwner, uint256 amountAfterFee, uint256 fee);

	/// @notice Emitted on emergency withdraw by platform owner
	event EmergencyWithdrawn(uint256 indexed saleId, address indexed token, address indexed to, uint256 amount);

	// -----------------------
	// Storage
	// -----------------------

	/// @notice Sales stored in a mapping by id
	mapping(uint256 => Sale) public sales; // saleId => Sale

	/// @notice Total number of sales created
	uint256 public totalSalesCount;

	/// @notice For quick lookup: sale address to saleId
	mapping(address => uint256) public saleIdOf;

	/// @notice User participation list: user => saleIds
	mapping(address => uint256[]) private _userSaleIds;

	constructor(address _treasury, address _usdt, address _usd1) {
		treasury = _treasury == address(0) ? msg.sender : _treasury;
		usdt = _usdt;
		usd1 = _usd1;
	}

	// -----------------------
	// Admin
	// -----------------------

	function setTreasury(address _treasury) external onlyOwner {
		require(_treasury != address(0), "treasury=0");
		emit TreasuryChanged(treasury, _treasury);
		treasury = _treasury;
	}

	/// @notice Update default sale duration for future sales
	function setDefaultSaleDuration(uint256 newDuration) external onlyOwner {
		require(newDuration >= 1 days && newDuration <= 365 days, "duration-range");
		emit DefaultSaleDurationChanged(defaultSaleDuration, newDuration);
		defaultSaleDuration = newDuration;
	}

	/// @notice Update sale creation fee
	function setSaleCreationFee(uint256 newFee) external onlyOwner {
		require(newFee <= 1 ether, "fee-too-high"); // Max 1 ETH to prevent mistakes
		emit SaleCreationFeeChanged(saleCreationFee, newFee);
		saleCreationFee = newFee;
	}

	function setPaymentTokenAddresses(address _usdt, address _usd1) external onlyOwner {
		usdt = _usdt;
		usd1 = _usd1;
	}

	function setQuoteSigner(address _signer) external onlyOwner {
		require(_signer != address(0), "signer=0");
		emit QuoteSignerChanged(quoteSigner, _signer);
		quoteSigner = _signer;
	}

	// -----------------------
	// Sale creation
	// -----------------------

	/// @notice Create a new sale. Requires SALE_CREATION_FEE paid in ETH.
	/// @param token Token to sell (ERC20)
	/// @param currency Payment currency type (NATIVE/USDT/USD1)
	/// @param vestingDuration Linear vesting duration in seconds (starts when sale ends)
	/// @param hardCap Hard cap in token units (1eTokenDecimals). Reaching this ends the sale early.
	/// @param discount Discount percentage in basis points (e.g., 500 = 5%)
	function createSale(
		address token,
		PaymentCurrency currency,
		uint256 vestingDuration,
		uint256 hardCap,
		uint256 discount
	) external payable nonReentrant returns (uint256 saleId, address saleAddress) {
		require(msg.value == saleCreationFee, "fee");
		require(token != address(0), "token=0");
		require(vestingDuration >= 1 days, "vesting");
		require(hardCap > 0, "hardCap");
		require(discount <= 10_000, "discount"); // max 100%

		// Validate currency availability
		if (currency == PaymentCurrency.USDT) require(usdt != address(0), "usdt=0");
		if (currency == PaymentCurrency.USD1) require(usd1 != address(0), "usd1=0");

		// Deploy child sale
		VestingSale child = new VestingSale(
			address(this),
			msg.sender,
			token,
			currency,
			block.timestamp,
			block.timestamp + defaultSaleDuration,
			vestingDuration,
			hardCap,
			discount
		);

		// Persist meta
		Sale memory meta = Sale({
			saleAddress: address(child),
			projectOwner: msg.sender,
			token: token,
			currency: currency,
			startTime: block.timestamp,
			endTime: block.timestamp + defaultSaleDuration,
			vestingDuration: vestingDuration,
			hardCap: hardCap,
			discount: discount,
			soldTokens: 0,
			buyersCount: 0,
			endedEarly: false
		});

		// Assign id and store
		totalSalesCount += 1;
		saleId = totalSalesCount;
		sales[saleId] = meta;
		saleIdOf[address(child)] = saleId;

		emit SaleCreated(
			saleId,
			address(child),
			msg.sender,
			token,
			currency,
			hardCap,
			discount,
			meta.startTime,
			meta.endTime,
			vestingDuration
		);

		// forward creation fee to treasury
		(bool ok, ) = payable(treasury).call{value: msg.value}("");
		require(ok, "fee-xfer");

		return (saleId, address(child));
	}

	// -----------------------
	// Child hooks (called by sales)
	// -----------------------

	/// @notice Called by child sale on each purchase to update platform indexes
	function onPurchase(address buyer, uint256 tokenAmount, uint256 paymentAmount) external {
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");

		Sale storage m = sales[id];
		// update sold
		m.soldTokens += tokenAmount;

		emit Purchased(id, buyer, paymentAmount, tokenAmount);
	}

	/// @notice Called by child only on the first participation of a buyer
	function onFirstParticipation() external {
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");
		Sale storage m = sales[id];
		m.buyersCount += 1;
	}

	/// @notice Called by child when sale ends early due to hard cap reached
	function onEndedEarly() external {
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");
		sales[id].endedEarly = true;
		sales[id].endTime = block.timestamp;
	}

	/// @notice Called by child on claim to bubble up event
	function onClaim(address buyer, uint256 amount) external {
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");
		emit Claimed(id, buyer, amount);
	}

	/// @notice Called by child when proceeds withdrawn by project owner
	function onProceedsWithdraw(uint256 amountAfterFee, uint256 fee) external {
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");
		emit ProceedsWithdrawn(id, sales[id].projectOwner, amountAfterFee, fee);
	}

	// -----------------------
	// Views (as requested)
	// -----------------------

	/// @notice Get current sale creation fee
	function getSaleCreationFee() external view returns (uint256) {
		return saleCreationFee;
	}

	/// @notice Return total sales count
	function totalSales() external view returns (uint256) {
		return totalSalesCount;
	}

	/// @notice Satışların id listesini aralıkla döndürür [fromId, toId] (dahil)
	function getSalesInRange(uint256 fromId, uint256 toId) external view returns (Sale[] memory list) {
		require(toId >= fromId, "range");
		require(toId <= totalSalesCount, "oob");
		uint256 len = toId - fromId + 1;
		list = new Sale[](len);
		for (uint256 i = 0; i < len; i++) {
			list[i] = sales[fromId + i];
		}
	}

	/// @notice Tekil satış verisini döndürür (struct olarak)
	function getSaleByIndex(uint256 saleId) external view returns (Sale memory) {
		return sales[saleId];
	}

	/// @notice Kullanıcının katıldığı satışların id listesi
	function getUserSaleIds(address user) external view returns (uint256[] memory) {
		return _userSaleIds[user];
	}

	// -----------------------
	// Emergency controls
	// -----------------------

	/// @notice Factory owner can withdraw any stuck funds/tokens from a child sale (emergency)
	function emergencyWithdrawFromSale(uint256 saleId, address token, address to, uint256 amount) external onlyOwner {
		require(saleId > 0 && saleId <= totalSalesCount, "oob");
		require(to != address(0), "to=0");
		VestingSale(payable(sales[saleId].saleAddress)).emergencyWithdraw(token, to, amount);
		emit EmergencyWithdrawn(saleId, token, to, amount);
	}

	function emergencyWithdrawETHFromSale(uint256 saleId, address to, uint256 amount) external onlyOwner {
		require(saleId > 0 && saleId <= totalSalesCount, "oob");
		require(to != address(0), "to=0");
		VestingSale(payable(sales[saleId].saleAddress)).emergencyWithdrawETH(to, amount);
		emit EmergencyWithdrawn(saleId, address(0), to, amount);
	}

	// -----------------------
	// Internal: record user participation (called by child)
	// -----------------------

	function _recordUserSale(address user) external {
		// only callable by a known sale
		uint256 id = saleIdOf[msg.sender];
		require(sales[id].saleAddress == msg.sender, "sale");
		_userSaleIds[user].push(id);
	}

}

/// @dev Child contract that holds sale state and vesting/claim logic
contract VestingSale is ReentrancyGuard {
	using SafeERC20 for IERC20;
	using ECDSA for bytes32;
	using MessageHashUtils for bytes32;

	// Immutable config
	VestingSalePlatform public immutable factory;
	address public immutable projectOwner;
	address public immutable token; // token being sold
	PaymentCurrency public immutable currency;
	uint256 public startTime;
	uint256 public endTime;
	uint256 public immutable vestingDuration;
	uint256 public immutable hardCap;
	uint256 public immutable discount;

	bool public endedEarly;
	bool public proceedsWithdrawn;

	// Accumulators
	uint256 public soldTokens; // total tokens allocated to buyers
	uint256 public buyersCount;
	uint256 public totalClaimed; // total tokens claimed by all users (accurate tracking)

	// Proceeds tracked per currency
	uint256 public totalRaisedNative; // ETH
	mapping(address => uint256) public totalRaisedERC20; // token => amount

	struct BuyerData {
		uint256 amount;  // total purchased tokens
		uint256 claimed; // already claimed
		bool participated;
	}
	mapping(address => BuyerData) public buyers;

	event Bought(address indexed buyer, uint256 payAmount, uint256 tokenAmount);
	event Claimed(address indexed buyer, uint256 amount);
	event EndedEarly(uint256 when);
	event ProceedsWithdrawn(address indexed to, uint256 amountAfterFee, uint256 fee);

	// Local constants (mirror platform fee constants)
	uint256 private constant FEE_BPS_LOCAL = 100; // 1%
	uint256 private constant BPS_DENOM_LOCAL = 10_000;

	modifier onlyProjectOwner() {
		require(msg.sender == projectOwner, "owner");
		_;
	}

	constructor(
		address _factory,
		address _projectOwner,
		address _token,
		PaymentCurrency _currency,
		uint256 _startTime,
		uint256 _endTime,
		uint256 _vestingDuration,
		uint256 _hardCap,
		uint256 _discount
	) {
		require(_factory != address(0) && _projectOwner != address(0) && _token != address(0), "zero");
		factory = VestingSalePlatform(payable(_factory));
		projectOwner = _projectOwner;
		token = _token;
		currency = _currency;
		startTime = _startTime;
		endTime = _endTime;
		vestingDuration = _vestingDuration;
		hardCap = _hardCap;
		discount = _discount;
	}

	// -------------
	// Sale state
	// -------------

	function isActive() public view returns (bool) {
		return block.timestamp >= startTime && block.timestamp < endTime && !endedEarly;
	}

	function hasEnded() public view returns (bool) {
		return endedEarly || block.timestamp >= endTime;
	}

	function _maybeEndEarly() internal {
		if (!endedEarly && soldTokens >= hardCap) {
			endedEarly = true;
			endTime = block.timestamp;
			emit EndedEarly(block.timestamp);
			factory.onEndedEarly();
		}
	}

	// -------------
	// Funding
	// -------------

	// Sequential nonce tracking to prevent collision: user => next expected nonce
	mapping(address => uint256) public userNonces;

	// Buy using backend-signed quote
	// For ETH: paymentToken = address(0) and msg.value == paymentAmount
	// For ERC20: paymentToken = USDT or USD1, and amount transferred via safeTransferFrom
	// Signature covers: saleAddress, buyer, paymentToken, paymentAmount, tokensOut, deadline, nonce
	function buyWithQuote(
		address paymentToken,
		uint256 paymentAmount,
		uint256 tokensOut,
		uint256 deadline,
		uint256 nonce,
		bytes calldata signature
	) external payable nonReentrant {
		require(isActive(), "inactive");
		require(block.timestamp <= deadline, "expired");
		
		// Sequential nonce validation to prevent collision
		require(nonce == userNonces[msg.sender], "invalid-nonce");
		userNonces[msg.sender]++; // Increment for next transaction
		
		require(tokensOut > 0 && paymentAmount > 0, "zero");

		// Validate payment token according to sale currency
		if (currency == PaymentCurrency.NATIVE) {
			require(paymentToken == address(0), "native-token");
			require(msg.value == paymentAmount, "value");
			require(msg.value > 0, "zero-value"); // Additional safety check
		} else if (currency == PaymentCurrency.USDT) {
			require(paymentToken == factory.usdt(), "!usdt");
			require(msg.value == 0, "no-eth-for-usdt"); // Ensure no ETH sent
		} else if (currency == PaymentCurrency.USD1) {
			require(paymentToken == factory.usd1(), "!usd1");
			require(msg.value == 0, "no-eth-for-usd1"); // Ensure no ETH sent
		}

		// Verify signature from factory.quoteSigner
		address signer = factory.quoteSigner();
		require(signer != address(0), "no-signer");

		bytes32 digest = keccak256(
			abi.encode(
				block.chainid,        // Add chain ID to prevent cross-chain replay
				address(this),        // Contract address
				msg.sender,           // Buyer address
				paymentToken,         // Payment token address
				paymentAmount,        // Payment amount
				tokensOut,           // Tokens to receive
				deadline,            // Transaction deadline
				nonce                // Unique nonce
			)
		).toEthSignedMessageHash();
		require(digest.recover(signature) == signer, "sig");

		// Enforce cap
		require(soldTokens + tokensOut <= hardCap, "cap");

		// Record buyer
		BuyerData storage b = buyers[msg.sender];
		if (!b.participated) {
			b.participated = true;
			buyersCount += 1;
			factory._recordUserSale(msg.sender);
			factory.onFirstParticipation();
		}
		b.amount += tokensOut;
		soldTokens += tokensOut;

		// Take payment - single validation point to prevent inconsistency
		if (currency == PaymentCurrency.NATIVE) {
			// ETH payment - already validated above
			totalRaisedNative += paymentAmount; // Use paymentAmount consistently
		} else {
			// ERC20 payment
			IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), paymentAmount);
			totalRaisedERC20[paymentToken] += paymentAmount;
		}

		factory.onPurchase(msg.sender, tokensOut, paymentAmount);
		emit Bought(msg.sender, paymentAmount, tokensOut);
		_maybeEndEarly();
	}

	// -------------
	// Claims (linear vesting)
	// -------------

	function vestingStart() public view returns (uint256) {
		return hasEnded() ? endTime : 0;
	}

	function vestedAmount(address user) public view returns (uint256) {
		BuyerData memory b = buyers[user];
		if (b.amount == 0) return 0;
		uint256 vs = vestingStart();
		if (vs == 0) return 0; // not started
		if (block.timestamp <= vs) return 0;
		if (vestingDuration == 0) return b.amount; // safety
		
		// Use precise time-based vesting instead of daily chunks to avoid precision loss
		uint256 elapsed = block.timestamp - vs;
		if (elapsed >= vestingDuration) return b.amount; // fully vested
		
		// Calculate vested amount with full precision: (amount * elapsed) / totalDuration
		// This eliminates precision loss from daily rounding
		return (b.amount * elapsed) / vestingDuration;
	}

	function claimable(address user) public view returns (uint256) {
		BuyerData memory b = buyers[user];
		uint256 v = vestedAmount(user);
		if (v <= b.claimed) return 0;
		return v - b.claimed;
	}

	function claim() external nonReentrant {
		uint256 amount = claimable(msg.sender);
		require(amount > 0, "no-claim");
		buyers[msg.sender].claimed += amount;
		totalClaimed += amount; // Accurate global tracking
		IERC20(token).safeTransfer(msg.sender, amount);
		factory.onClaim(msg.sender, amount);
		emit Claimed(msg.sender, amount);
	}

	// -------------
	// Project withdrawals
	// -------------

	/// @notice Project owner withdraws raised funds after sale ended
	function withdrawProceeds() external nonReentrant onlyProjectOwner {
		require(hasEnded(), "not-ended");
		require(!proceedsWithdrawn, "done");
		proceedsWithdrawn = true;

		address treasury = factory.treasury();

		if (currency == PaymentCurrency.NATIVE) {
			uint256 bal = address(this).balance;
			uint256 fee = (bal * FEE_BPS_LOCAL) / BPS_DENOM_LOCAL;
			uint256 net = bal - fee;
			if (fee > 0) {
				(bool ok1, ) = payable(treasury).call{value: fee}("");
				require(ok1, "fee-xfer");
			}
			(bool ok2, ) = payable(projectOwner).call{value: net}("");
			require(ok2, "net-xfer");
			factory.onProceedsWithdraw(net, fee);
			emit ProceedsWithdrawn(projectOwner, net, fee);
		} else {
			address payment = currency == PaymentCurrency.USDT ? factory.usdt() : factory.usd1();
			uint256 bal = IERC20(payment).balanceOf(address(this));
			uint256 fee = (bal * FEE_BPS_LOCAL) / BPS_DENOM_LOCAL;
			uint256 net = bal - fee;
			if (fee > 0) IERC20(payment).safeTransfer(treasury, fee);
			IERC20(payment).safeTransfer(projectOwner, net);
			factory.onProceedsWithdraw(net, fee);
			emit ProceedsWithdrawn(projectOwner, net, fee);
		}
	}

	/// @notice Project owner can withdraw remaining unsold tokens after sale ended
	function withdrawUnsoldTokens(address to) external onlyProjectOwner {
		require(hasEnded(), "not-ended");
		require(to != address(0), "to=0");
		
		uint256 bal = IERC20(token).balanceOf(address(this));
		uint256 neededForUnclaimed = soldTokens - totalClaimed; // Use accurate totalClaimed
		require(bal > neededForUnclaimed, "none");
		
		uint256 excess = bal - neededForUnclaimed;
		require(excess > 0, "no-excess");
		
		IERC20(token).safeTransfer(to, excess);
	}

	/// @notice Get total tokens that need to remain in contract for unclaimed vesting
	function getRequiredTokenBalance() external view returns (uint256) {
		return soldTokens - totalClaimed;
	}

	// -------------
	// Emergency controls (factory owner)
	// -------------

	function emergencyWithdraw(address erc20, address to, uint256 amount) external {
		require(msg.sender == address(factory), "factory-only");
		require(to != address(0), "to=0");
		IERC20(erc20).safeTransfer(to, amount);
	}

	function emergencyWithdrawETH(address to, uint256 amount) external {
		require(msg.sender == address(factory), "factory-only");
		require(to != address(0), "to=0");
		(bool ok, ) = payable(to).call{value: amount}("");
		require(ok, "eth-xfer");
	}

	// -------------
	// Views for UI convenience
	// -------------

	function getBuyerInfo(address user) external view returns (PurchaseInfo memory info, uint256 pending) {
		BuyerData memory b = buyers[user];
		info = PurchaseInfo({
			saleAddress: address(this),
			amount: b.amount,
			claimed: b.claimed,
			participated: b.participated
		});
		uint256 c = claimable(user);
		return (info, c);
	}

	receive() external payable {}
	fallback() external payable {}
}

