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

    // IPFS Base URI for Filebase
    string private _customBaseURI;

    struct Tier {
        uint256 price;
        uint256 maxSupply;
        uint256 minted;
    }

    mapping(uint8 => Tier) public tiers;
    
    // Maps a specific Token ID to its Tier (Type)
    mapping(uint256 => uint8) public tokenTier; 

    event NFTBought(address indexed buyer, uint256 tokenId, uint8 tier);
    event RewardNFTMinted(address indexed to, uint256 tokenId, uint8 tier);
    event BaseURIUpdated(string newBaseURI);

    constructor(address _usdt, address _ownerWallet) ERC721("HMT Reward NFT", "HMT-NFT") Ownable(msg.sender) {
        USDT = IERC20(_usdt);
        ownerWallet = _ownerWallet;

        // Initialize Tiers
        tiers[1] = Tier(1000 * 1e18, 4000, 0);
        tiers[2] = Tier(2500 * 1e18, 3000, 0);
        tiers[3] = Tier(5000 * 1e18, 2000, 0);
        tiers[4] = Tier(10000 * 1e18, 1000, 0);
        tiers[5] = Tier(25000 * 1e18, 250, 0);
        tiers[6] = Tier(50000 * 1e18, 100, 0);
        tiers[7] = Tier(100000 * 1e18, 50, 0);
    }

    // ==========================================
    // 🌐 FRONTEND HELPER (RPC SAFE)
    // ==========================================

    /**
     * @notice Returns an array of all Token IDs currently owned by a specific wallet.
     * @dev This eliminates the need for the frontend to scan RPC logs for Transfer events.
     */
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

    /**
     * @dev Automatically formats the IPFS link based on the TIER, not the Token ID.
     * Example: Token ID 1500 is a Tier 4 NFT. This returns ipfs://.../4.json
     */
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