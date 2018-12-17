pragma solidity ^0.4.20;


interface IERC721Base {
    function assetsOf(address _owner) external view returns (uint256[]);
    function totalSupply() external view returns (uint256);
    function tokenByIndex(uint256 _index) external view returns (uint256);
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256);
    function ownerOf(uint256 _assetId) external view returns (address);
    function balanceOf(address _owner) external view returns (uint256);
    function isApprovedForAll(address _operator, address _assetHolder) external view returns (bool);
    function getApprovedAddress(uint256 _assetId) external view returns (address);
    function isAuthorized(address _operator, uint256 _assetId) external view returns (bool);

    function setApprovalForAll(address _operator, bool _authorized) external;
    function approve(address _operator, uint256 _assetId) external;
    function safeTransferFrom(address _from, address _to, uint256 _assetId) external;
    function safeTransferFrom(address _from, address _to, uint256 _assetId, bytes _userData) external;
    function transferFrom(address _from, address _to, uint256 _assetId) external;
}
