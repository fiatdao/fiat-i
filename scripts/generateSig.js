const ethUtil = require('ethereumjs-util');
const sigUtil = require('eth-sig-util');
const utils = sigUtil.TypedDataUtils;

//Our lad Cal wants to send 2 FIAT to del, by signing a cheque and paying a 1 FIAT fee to msg.sender

const calprivKeyHex = '9e99449797b670840f53a749df174a19772bcd4c6b52e976ab139812d4646f0a'
const calprivKey = new Buffer.from(calprivKeyHex, 'hex')
const cal = ethUtil.privateToAddress(calprivKey);
const del = new Buffer.from('0D1d31abea2384b0D5add552E3a9b9F66d57e141', 'hex');
const fiat = new Buffer.from('f925e7d14E89736700B73CA27ECceeB0A088383f', 'hex');
console.log('cals address: ' + '0x' + cal.toString('hex'));
console.log('dels address: ' + '0x' + del.toString('hex'));
let typedData = {
    types: {
        EIP712Domain: [
            { name: 'name', type: 'string' },
            { name: 'version', type: 'string' },
            { name: 'chainId', type: 'uint256' },
            { name: 'verifyingContract', type: 'address' }
        ],
        Permit: [
            { name: 'owner', type: 'address' },
            { name: 'spender', type: 'address' },
            { name: 'value', type: 'uint256' },
            { name: 'nonce', type: 'uint256' },
            { name: 'deadline', type: 'uint256' }
        ],
    },
    primaryType: 'Permit',
    domain: {
        name: 'Fixed Income Asset Token',
        version: '1',
        chainId: '99',
        verifyingContract: '0xf925e7d14e89736700b73ca27ecceeb0a088383f', //in hevm
    },
    message: {
        owner: '0x'+cal.toString('hex'),
        spender: '0x'+del.toString('hex'),
        value: '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        nonce: 0,
        deadline: '0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' // 604411200 + 3600
    },
};

let hash = ethUtil.bufferToHex(utils.hashStruct('EIP712Domain', typedData.domain, typedData.types))
console.log('EIP712DomainHash: ' + hash);
hash = ethUtil.bufferToHex(utils.hashType('Permit', typedData.types))
console.log('Permit Typehash: ' + hash);
hash = ethUtil.bufferToHex(utils.hashStruct('Permit', typedData.message, typedData.types))
console.log('Permit (from cal to del) hash: ' + hash);
const sig = sigUtil.signTypedData(calprivKey, { data: typedData });
console.log('signed permit: ' + sig);

let r = sig.slice(0,66);
let s = '0x'+ sig.slice(66,130);
let v = ethUtil.bufferToInt(ethUtil.toBuffer('0x'+sig.slice(130,132),'hex'));

console.log('r: ' + r)
console.log('s: ' + s)
console.log('v: ' + v)
