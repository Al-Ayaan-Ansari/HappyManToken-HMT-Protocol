// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol"; 

contract HMT_NFT is ERC721, ERC721Enumerable, Ownable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    IERC20 public USDT;
    address public ownerWallet;
    address public miningContract;
    uint256 public nextTokenId = 1;

    string private _customBaseURI;

    struct Tier {
        uint256 price;
        uint256 maxSupply;
        uint256 minted;
        uint256 ownerMinted; // 🟢 UPGRADED: Tracks exact number of NFTs minted to owner for batching
    }

    mapping(uint8 => Tier) public tiers;
    mapping(uint256 => uint8) public tokenTier; 

    event NFTBought(address indexed buyer, uint256 tokenId, uint8 tier);
    event RewardNFTMinted(address indexed to, uint256 tokenId, uint8 tier);
    event BaseURIUpdated(string newBaseURI);

    constructor(address _usdt, address _ownerWallet) ERC721("HMT Reward NFT", "HMT-NFT") Ownable(msg.sender) {
        USDT = IERC20(_usdt);
        ownerWallet = _ownerWallet;

        // 🟢 UPDATED: Initialize ownerMinted counter to 0 instead of false
        tiers[1] = Tier(1000 * 1e18, 5000, 0, 0);
        tiers[2] = Tier(2500 * 1e18, 4000, 0, 0);
        tiers[3] = Tier(5000 * 1e18, 3000, 0, 0);
        tiers[4] = Tier(10000 * 1e18, 2000, 0, 0);
        tiers[5] = Tier(25000 * 1e18, 1000, 0, 0);
        tiers[6] = Tier(50000 * 1e18, 500, 0, 0);
        tiers[7] = Tier(100000 * 1e18, 250, 0, 0);
    }

    // ==========================================
    // 🟢 SMART BATCH ALLOCATION MINTING
    // ==========================================
    
    /**
     * @notice Mints the 10% owner allocation in safe batches of 100 across all tiers.
     * @dev Just keep calling this function until it reverts with "All allocations claimed".
     */
    function claimOwnerAllocation() external onlyOwner {
        uint256 batchLimit = 100;
        uint256 mintedThisTx = 0;

        // Automatically scans Tier 1 through Tier 7
        for (uint8 i = 1; i <= 7; i++) {
            Tier storage t = tiers[i];
            
            uint256 totalAllocation = t.maxSupply / 10; // 10% of total supply
            uint256 remainingForThisTier = totalAllocation - t.ownerMinted;

            if (remainingForThisTier > 0) {
                // Calculate how many to mint in this specific iteration
                uint256 toMint = remainingForThisTier;
                
                // If adding this tier's remainder exceeds our 100 batch limit, cap it
                if (mintedThisTx + toMint > batchLimit) {
                    toMint = batchLimit - mintedThisTx;
                }

                require(t.minted + toMint <= t.maxSupply, "Exceeds max supply");

                // Update state before external minting calls
                t.ownerMinted += toMint;
                t.minted += toMint;

                // Mint the batch
                for (uint256 j = 0; j < toMint; j++) {
                    uint256 tokenId = nextTokenId++;
                    tokenTier[tokenId] = i;
                    _safeMint(ownerWallet, tokenId);
                }

                mintedThisTx += toMint;

                // If we hit our 100 NFT block gas safety limit, halt execution until next call
                if (mintedThisTx >= batchLimit) {
                    break;
                }
            }
        }
        
        // Reverts only when all 1,575 NFTs across all 7 tiers have been fully minted
        require(mintedThisTx > 0, "All allocations claimed");
    }

    // ==========================================
    // 🌐 FRONTEND HELPER (RPC SAFE)
    // ==========================================

    function getUserTokens(address _user) external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_user);
        uint256[] memory tokens = new uint256[](tokenCount);
        
        for (uint256 i = 0; i < tokenCount; i++) {
            tokens[i] = tokenOfOwnerByIndex(_user, i);
        }
        
        return tokens;
    }

    // ==========================================
    // 🌐 FILEBASE / IPFS METADATA ENGINE
    // ==========================================

    function setBaseURI(string memory newBaseURI) external onlyOwner {
        _customBaseURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _customBaseURI;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireOwned(tokenId);
        uint8 tier = tokenTier[tokenId];
        string memory baseURI = _baseURI();
        
        return bytes(baseURI).length > 0 
            ? string(abi.encodePacked(baseURI, uint256(tier).toString(), ".json")) 
            : "";
    }

    // ==========================================
    // ⚙️ SYSTEM SETTINGS & MINTING
    // ==========================================

    function setMiningContract(address _miningContract) external onlyOwner {
        miningContract = _miningContract;
    }

    function buyNFT(uint8 _tier) external {
        require(_tier >= 1 && _tier <= 7, "Invalid Tier");
        Tier storage t = tiers[_tier];
        require(t.minted < t.maxSupply, "Tier completely sold out");

        USDT.safeTransferFrom(msg.sender, ownerWallet, t.price);

        t.minted++;
        uint256 tokenId = nextTokenId++;
        tokenTier[tokenId] = _tier;

        _safeMint(msg.sender, tokenId);
        emit NFTBought(msg.sender, tokenId, _tier);
    }

    function mintRewardNFT(address to, uint8 _tier) external {
        require(msg.sender == miningContract, "Only Mining Contract can mint rewards");
        require(_tier >= 1 && _tier <= 7, "Invalid Tier");
        
        Tier storage t = tiers[_tier];
        require(t.minted < t.maxSupply, "Tier completely sold out");

        t.minted++;
        uint256 tokenId = nextTokenId++;
        tokenTier[tokenId] = _tier;

        _safeMint(to, tokenId);
        emit RewardNFTMinted(to, tokenId, _tier);
    }

    function getNFTTier(uint256 tokenId) external view returns (uint8) {
        return tokenTier[tokenId];
    }

    function getTierPrice(uint8 _tier) external view returns (uint256) {
        return tiers[_tier].price;
    }

    // ==========================================
    // 🔒 REQUIRED OVERRIDES FOR ENUMERABLE
    // ==========================================

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}