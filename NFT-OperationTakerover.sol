// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "operator-filter-registry/src/DefaultOperatorFilterer.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";

contract OperationTakeover_NFT is ReentrancyGuard, Pausable, ERC721Enumerable, Ownable, IERC721Receiver, DefaultOperatorFilterer, ERC2981 {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    /* ------------------------ NFT Minting ------------------------- */
    uint256 public m_nMaxSupply = 10000;
    uint256 public m_nWhitelistPrice = 0.019 ether;
    uint256 public m_nPublicPrice = 0.019 ether;
    uint8 public m_nSaleStep = 0; // 0: NONE, 1: WHITELIST, 2: PUBLIC
    uint256 public m_nWhitelistMintLimit = 5;
    uint256 public m_nPublicMintLimit = 10;
    mapping(address => uint256) public m_mapWhitelistMintAmount;
    mapping(address => uint256) public m_mapPublicMintAmount;
    bool public m_bRevealEnabled = false;
    string private m_strTokenBaseURI = "";
    string private m_strUnrevealURI = "";
    uint256 internal m_nMintIndexer = 0;
    mapping(address => bool) public m_mapWhitelist;
    bytes32 public m_merkleRootOfWhitelist;

    /* ------------------------ NFT Staking ------------------------- */
    enum Rarity {
        ASSOCIATE,
        SOLDIER,
        CAPOREGIME,
        CONSIGLIERE,
        UNDERBOSS,
        BOSS
    }
    struct UserInfo {
        uint256 rewardsPerDay;
        uint256 unpaidRewards;
        uint256 paidRewards;
        uint256 lastUpdatedTime;
    }
    mapping(address => UserInfo) public m_mapUserInfo;
    mapping(address => EnumerableSet.UintSet) internal m_stakedNfts;
    IERC20 public m_tokenReward;
    mapping(Rarity => uint256) public m_mapDailyRewardsOfRairity;
    bytes32 public m_merkleRootOfRarity;

    event Staked(address indexed account, uint256[] ids);
    event UnStaked(address indexed account, uint256[] ids);
    event Harvested(address indexed account, uint256 amount);
    /* --------------------------------------------------------------------------------- */

    constructor(address _rewardToken) ERC721("Operation Takeover", "Agent") {
        m_tokenReward = IERC20(_rewardToken);
        
        m_mapDailyRewardsOfRairity[Rarity.ASSOCIATE] = 10 ether;
        m_mapDailyRewardsOfRairity[Rarity.SOLDIER] = 12 ether;
        m_mapDailyRewardsOfRairity[Rarity.CAPOREGIME] = 14 ether;
        m_mapDailyRewardsOfRairity[Rarity.CONSIGLIERE] = 16 ether;
        m_mapDailyRewardsOfRairity[Rarity.UNDERBOSS] = 18 ether;
        m_mapDailyRewardsOfRairity[Rarity.BOSS] = 20 ether;
    }

    function setApprovalForAll(address operator, bool approved) public override(ERC721, IERC721) onlyAllowedOperatorApproval(operator) {
        super.setApprovalForAll(operator, approved);
    }

    function approve(address operator, uint256 tokenId) public override(ERC721, IERC721) onlyAllowedOperatorApproval(operator) {
        super.approve(operator, tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721, IERC721) onlyAllowedOperator(from) {
        super.transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public override(ERC721, IERC721) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public override(ERC721, IERC721) onlyAllowedOperator(from) {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    /* ------------------------ NFT Minting Settings------------------------- */
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    function setMaxSupply(uint256 _maxSupply) external onlyOwner {
        m_nMaxSupply = _maxSupply;
    }

    function setMintPrice(uint256 _whitelistPrice, uint256 _publicPrice) external onlyOwner {
        m_nWhitelistPrice = _whitelistPrice;
        m_nPublicPrice = _publicPrice;
    }

    function setSaleStep(uint8 _saleStep) external onlyOwner {
        m_nSaleStep = _saleStep;
    }

    function setMintLimit(uint256 _whitelistMintLimit, uint256 _publicMintLimit) external onlyOwner {
        m_nWhitelistMintLimit = _whitelistMintLimit;
        m_nPublicMintLimit = _publicMintLimit;
    }

    function setRevealEnabled(bool _bEnable) external onlyOwner {
        m_bRevealEnabled = _bEnable;
    }

    function setTokenBaseURI(string memory _tokenBaseURI) external onlyOwner {
        m_strTokenBaseURI = _tokenBaseURI;
    }

    function setUnrevealURI(string memory _unrevealURI) external onlyOwner {
        m_strUnrevealURI = _unrevealURI;
    }
    
    function setWhiteList(address[] memory _addressList, bool _bEnable) external onlyOwner {
        for (uint256 i = 0; i < _addressList.length; i++) {
            m_mapWhitelist[_addressList[i]] = _bEnable;
        }
    }

    function setMerkleRootOfWhitelist(bytes32 _root) external onlyOwner {
        m_merkleRootOfWhitelist = _root;
    }

    /* ------------------------ NFT Staking Settings ------------------------- */

    function setRewardToken(address _rewardToken) external onlyOwner {
        m_tokenReward = IERC20(_rewardToken);
    }

    function setDailyRewardsOfRarity(uint8 _rarityIndex, uint256 _dailyRewards) external onlyOwner {
        m_mapDailyRewardsOfRairity[Rarity(_rarityIndex)] = _dailyRewards;
    }

    function setMerkleRootOfRarity(bytes32 _root) external onlyOwner {
        m_merkleRootOfRarity = _root;
    }
    
    /* ------------------------ NFT Minting Functions ------------------------- */
    
    function airdrop(address[] memory _airdropAddress, uint256 _numberOfTokens) external onlyOwner {
        uint256 currentIndex = m_nMintIndexer;
        require(currentIndex + _airdropAddress.length * _numberOfTokens <= m_nMaxSupply, "Purchase would exceed m_nMaxSupply");

        for (uint256 k = 0; k < _airdropAddress.length; k++) {
            for (uint256 i = 0; i < _numberOfTokens; i++) {
                _safeMint(_airdropAddress[k], currentIndex);
                currentIndex++;
            }
        }

        m_nMintIndexer = currentIndex;
    }

    function whitelistMint(uint256 _numberOfTokens, bytes32[] calldata _proof) external payable {
        uint256 currentIndex = m_nMintIndexer;
        require(currentIndex + _numberOfTokens <= m_nMaxSupply, "Purchase would exceed m_nMaxSupply");
        require(m_nSaleStep == 1, "Whitelist Mint is not activated.");
        require(MerkleProof.verify(_proof, m_merkleRootOfWhitelist, keccak256(abi.encodePacked(_msgSender()))) || m_mapWhitelist[_msgSender()], "Invalid proof");
        require(m_mapWhitelistMintAmount[_msgSender()] + _numberOfTokens <= m_nWhitelistMintLimit, "Purchase would exceed m_nWhitelistMintLimit");
        require(m_nWhitelistPrice * _numberOfTokens <= msg.value, "ETH amount is not sufficient");

        for (uint256 i = 0; i < _numberOfTokens; i++) {
            _safeMint(_msgSender(), currentIndex);
            currentIndex++;
        }

        m_nMintIndexer = currentIndex;
        m_mapWhitelistMintAmount[_msgSender()] += _numberOfTokens;
    }

    function publicMint(uint256 _numberOfTokens) external payable {
        uint256 currentIndex = m_nMintIndexer;
        require(currentIndex + _numberOfTokens <= m_nMaxSupply, "Purchase would exceed m_nMaxSupply");
        require(m_nSaleStep == 2, "Public Mint is not activated.");
        require(m_mapPublicMintAmount[_msgSender()] + _numberOfTokens <= m_nPublicMintLimit, "Purchase would exceed m_nPublicMintLimit");
        require(m_nPublicPrice * _numberOfTokens <= msg.value, "ETH amount is not sufficient");

        for (uint256 i = 0; i < _numberOfTokens; i++) {
            _safeMint(_msgSender(), currentIndex);
            currentIndex++;
        }

        m_nMintIndexer = currentIndex;
        m_mapPublicMintAmount[_msgSender()] += _numberOfTokens;
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        require(_exists(tokenId), "Token does not exist");

        if (m_bRevealEnabled) {
            return string(abi.encodePacked(m_strTokenBaseURI, tokenId.toString()));
        }
        return m_strUnrevealURI;
    }

    function withdraw() external onlyOwner {
        payable(_msgSender()).transfer(address(this).balance);
    }

    /* ------------------------ NFT Staking Functions ------------------------- */
    function stake(uint256[] memory _tokenIds, uint8[] memory _rarities, bytes32[][] memory _proofs) external nonReentrant whenNotPaused {
        UserInfo storage user = m_mapUserInfo[_msgSender()];

        user.unpaidRewards = pendingRewards(_msgSender());
        user.lastUpdatedTime = block.timestamp;

        uint256 dailyRewardsOfRarities = 0;
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(MerkleProof.verify(_proofs[i], m_merkleRootOfRarity, keccak256(abi.encodePacked(_tokenIds[i], _rarities[i]))), "Verify failed");

            safeTransferFrom(_msgSender(), address(this), _tokenIds[i]);
            m_stakedNfts[_msgSender()].add(_tokenIds[i]);
            dailyRewardsOfRarities += m_mapDailyRewardsOfRairity[Rarity(_rarities[i])];
        }

        user.rewardsPerDay += dailyRewardsOfRarities;
        emit Staked(_msgSender(), _tokenIds);
    }

    function unstake(uint256[] memory _tokenIds, uint8[] memory _rarities, bytes32[][] memory _proofs) external nonReentrant {
        UserInfo storage user = m_mapUserInfo[_msgSender()];
        
        user.unpaidRewards = pendingRewards(_msgSender());
        user.lastUpdatedTime = block.timestamp;

        uint256 dailyRewardsOfRarities = 0;
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            require(m_stakedNfts[_msgSender()].contains(_tokenIds[i]), "Not owned");
            require(MerkleProof.verify(_proofs[i], m_merkleRootOfRarity, keccak256(abi.encodePacked(_tokenIds[i], _rarities[i]))), "Verify failed");

            _safeTransfer(address(this), _msgSender(), _tokenIds[i], "");
            m_stakedNfts[_msgSender()].remove(_tokenIds[i]);
            dailyRewardsOfRarities += m_mapDailyRewardsOfRairity[Rarity(_rarities[i])];
        }

        user.rewardsPerDay -= dailyRewardsOfRarities;
        emit UnStaked(_msgSender(), _tokenIds);
    }

    function harvest() external nonReentrant {
        UserInfo storage user = m_mapUserInfo[_msgSender()];

        uint256 pending = pendingRewards(_msgSender());
        
        require(pending > 0, "No rewards");

        m_tokenReward.safeTransfer(_msgSender(), pending);
        
        user.unpaidRewards = 0;
        user.lastUpdatedTime = block.timestamp;
        user.paidRewards += pending;

        emit Harvested(_msgSender(), pending);
    }

    function pendingRewards(address _owner) public view returns (uint256) {
        UserInfo memory user = m_mapUserInfo[_owner];
        uint256 amount = (block.timestamp - user.lastUpdatedTime) * user.rewardsPerDay / 1 days;
        return user.unpaidRewards + amount;
    }

    function withdrawToken() external onlyOwner {
        m_tokenReward.safeTransfer(_msgSender(), m_tokenReward.balanceOf(address(this)));
    }

    function holdingNFTs(address _owner) public view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_owner);
        uint256[] memory result = new uint256[](tokenCount);
        for (uint256 index = 0; index < tokenCount; index++) {
            result[index] = tokenOfOwnerByIndex(_owner, index);
        }
        return result;
    }

    function stakedNFTs(address _owner) external view returns (uint256[] memory) {
        uint256 tokenCount = m_stakedNfts[_owner].length();
        uint256[] memory result = new uint256[](tokenCount);
        for (uint256 index = 0; index < tokenCount; index++) {
            result[index] = m_stakedNfts[_owner].at(index);
        }
        return result;
    }

    function userStakeInfo(address _owner) external view returns (UserInfo memory) {
        return m_mapUserInfo[_owner];
    }

    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
