pragma solidity >=0.8.4;

import "./PriceOracle.sol";
import "./BaseRegistrarImplementation.sol";
import "./StringUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../resolvers/Resolver.sol";

/**
 * @dev A registrar controller for registering and renewing names at fixed cost.
 */
contract ETHRegistrarController is Ownable {
    using StringUtils for *;

    uint constant public MIN_REGISTRATION_DURATION = 28 days;

    bytes4 constant private INTERFACE_META_ID = bytes4(keccak256("supportsInterface(bytes4)"));
    bytes4 constant private COMMITMENT_CONTROLLER_ID = bytes4(
        keccak256("rentPrice(string,uint256)") ^
        keccak256("available(string)") ^
        keccak256("makeCommitment(string,address,bytes32)") ^
        keccak256("commit(bytes32)") ^
        keccak256("register(string,address,uint256,bytes32)") ^
        keccak256("renew(string,uint256)")
    );

    bytes4 constant private COMMITMENT_WITH_CONFIG_CONTROLLER_ID = bytes4(
        keccak256("registerWithConfig(string,address,uint256,bytes32,address,address)") ^
        keccak256("makeCommitmentWithConfig(string,address,bytes32,address,address)")
    );

    BaseRegistrarImplementation base;
    PriceOracle prices;
    //最小预提交间隔时间，单位：秒
    uint public minCommitmentAge;
    //最大预提交间隔时间，单位：秒
    uint public maxCommitmentAge;
    //存储预提交记录的时间戳
    mapping(bytes32=>uint) public commitments;

    event NameRegistered(string name, bytes32 indexed label, address indexed owner, uint cost, uint expires);
    event NameRenewed(string name, bytes32 indexed label, uint cost, uint expires);
    event NewPriceOracle(address indexed oracle);

    constructor(BaseRegistrarImplementation _base, PriceOracle _prices, uint _minCommitmentAge, uint _maxCommitmentAge) public {
        require(_maxCommitmentAge > _minCommitmentAge);

        base = _base;
        prices = _prices;
        minCommitmentAge = _minCommitmentAge;
        maxCommitmentAge = _maxCommitmentAge;
    }

    function rentPrice(string memory name, uint duration) view public returns(uint) {
        bytes32 hash = keccak256(bytes(name));
        return prices.price(name, base.nameExpires(uint256(hash)), duration);
    }

    function valid(string memory name) public pure returns(bool) {
        return name.strlen() >= 3;
    }

    function available(string memory name) public view returns(bool) {
        bytes32 label = keccak256(bytes(name));
        return valid(name) && base.available(uint256(label));
    }

    function makeCommitment(string memory name, address owner, bytes32 secret) pure public returns(bytes32) {
        return makeCommitmentWithConfig(name, owner, secret, address(0), address(0));
    }

    /**
    * @dev 生成commitment参数
    * @param name ens名
    * @param owner 注册者
    * @param secret 32随机字节
    * @param resolver 正向解析器地睛
    * @param addr 正向解析目标地址
    */
    function makeCommitmentWithConfig(string memory name, address owner, bytes32 secret, address resolver, address addr) pure public returns(bytes32) {
        bytes32 label = keccak256(bytes(name));
        if (resolver == address(0) && addr == address(0)) {
            return keccak256(abi.encodePacked(label, owner, secret));
        }
        require(resolver != address(0));
        return keccak256(abi.encodePacked(label, owner, resolver, addr, secret));
    }

    /**
    * @dev 预提交
    * @param commitment 提交参数
    */
    function commit(bytes32 commitment) public {
        require(commitments[commitment] + maxCommitmentAge < block.timestamp);//当重复预提交时，如果时间还未超过最大时间间隔，就不用再重新更新时间戳
        commitments[commitment] = block.timestamp;//记录本此提交的时间戳
    }

    function register(string calldata name, address owner, uint duration, bytes32 secret) external payable {
      registerWithConfig(name, owner, duration, secret, address(0), address(0));
    }

    /**
    * @dev 注册ens并配置
    * @param name ens名
    * @param owner 注册者
    * @param duration 域名有效时间
    * @param secret 32随机字节
    * @param resolver 正向解析器地睛
    * @param addr 正向解析目标地址
    */
    function registerWithConfig(string memory name, address owner, uint duration, bytes32 secret, address resolver, address addr) public payable {
        bytes32 commitment = makeCommitmentWithConfig(name, owner, secret, resolver, addr);
        uint cost = _consumeCommitment(name, duration, commitment);

        bytes32 label = keccak256(bytes(name));
        uint256 tokenId = uint256(label);

        uint expires;
        //存在正向解析器
        if(resolver != address(0)) {
            //mint NFT,设置ens的注册者为address(this)，这里先临街把注册者设为当前合约地址，
            //因为后面要setResolver时，要求msg.sender是合约注册者，如果直接把注册者给到owner，那在setResolver时就会fail
            expires = base.register(tokenId, address(this), duration);

            //计算nodehash
            bytes32 nodehash = keccak256(abi.encodePacked(base.baseNode(), label));

            //设置正向解析器地址
            base.ens().setResolver(nodehash, resolver);

            //如果正向解析地址不为0，就设置正向解析地址
            if (addr != address(0)) {
                Resolver(resolver).setAddr(nodehash, addr);
            }

            //用owner重新认领这个ens
            base.reclaim(tokenId, owner);
            //转移erc721 NFT给owner
            base.transferFrom(address(this), owner, tokenId);
        } else {//不存在正向解析器，直接把注册者设为owner就可以了
            require(addr == address(0));
            expires = base.register(tokenId, owner, duration);
        }
        //emit注册事件
        emit NameRegistered(name, label, owner, cost, expires);

        //发送过来的eth超过了费用，就退还
        if(msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }
    }

    function renew(string calldata name, uint duration) external payable {
        uint cost = rentPrice(name, duration);
        require(msg.value >= cost);

        bytes32 label = keccak256(bytes(name));
        uint expires = base.renew(uint256(label), duration);

        if(msg.value > cost) {
            payable(msg.sender).transfer(msg.value - cost);
        }

        emit NameRenewed(name, label, cost, expires);
    }

    function setPriceOracle(PriceOracle _prices) public onlyOwner {
        prices = _prices;
        emit NewPriceOracle(address(prices));
    }

    function setCommitmentAges(uint _minCommitmentAge, uint _maxCommitmentAge) public onlyOwner {
        minCommitmentAge = _minCommitmentAge;
        maxCommitmentAge = _maxCommitmentAge;
    }

    function withdraw() public onlyOwner {
        payable(msg.sender).transfer(address(this).balance);        
    }

    function supportsInterface(bytes4 interfaceID) external pure returns (bool) {
        return interfaceID == INTERFACE_META_ID ||
               interfaceID == COMMITMENT_CONTROLLER_ID ||
               interfaceID == COMMITMENT_WITH_CONFIG_CONTROLLER_ID;
    }

    function _consumeCommitment(string memory name, uint duration, bytes32 commitment) internal returns (uint256) {
        //commit之后必须等待最小间隔时间后才能注册，当前是60秒
        require(commitments[commitment] + minCommitmentAge <= block.timestamp);

        //不能超过commit之后的最大间隔境，当前是7天
        require(commitments[commitment] + maxCommitmentAge > block.timestamp);
        require(available(name));//这个ens要可用

        delete(commitments[commitment]);//删除预提交信息，gas返还

        uint cost = rentPrice(name, duration);//根据域名购买的有效时间，计算费用
        require(duration >= MIN_REGISTRATION_DURATION);//有效时间不能小于最小时间，当前是28天
        require(msg.value >= cost);//传入的eth要>=费用

        return cost;
    }
}
