import Web3 = require('web3')
import Promise = require('bluebird')
import * as util from 'ethereumjs-util'
import { ChannelId, ethHash, PaymentChannel, Signature } from './channel'
import { Buffer } from 'buffer'

const EXTRA_DIGITS = 3
export function randomNonce (): number {
  const datePart = new Date().getTime() * Math.pow(10, EXTRA_DIGITS)
  // 3 random digits
  const extraPart = Math.floor(Math.random() * Math.pow(10, EXTRA_DIGITS))
  // 16 digits
  return datePart + extraPart
}

export interface PaymentJSON {
  channelId: string
  sender: string
  receiver: string
  price: number
  value: number
  channelValue: number
  nonce: number
  v: number|string
  r: string
  s: string
}

export function digest (channelId: string|ChannelId, value: number): Buffer {
  const message = channelId.toString() + value.toString()
  return Buffer.from(message)
}

export function sign (web3: Web3, sender: string, digest: Buffer): Promise<Signature> {
  return new Promise<Signature>((resolve, reject) => {
    const message = digest.toString()
    const sha3 = ethHash(message)
    web3.eth.sign(sender, sha3, (error, signature) => {
      if (error) {
        reject(error)
      } else {
        resolve(util.fromRpcSig(signature))
      }
    })
  })
}

function pack(...bits): string {
  let res = '';
  for (let bit of bits) {
    let [typ, len, val] = bit;
    let packed = '';
    switch (typ) {
      case 'hex':
        if (val.len % 2 != 0)
          throw new Error(`Invalid hex string while packing bit: ${bit}`);
        let valByteLen = val.length / 2;
        for (let i = 0; i < valByteLen; i += 1)
          packed += String.fromCharCode(parseInt(val.slice(i, i + 2), 16));
        break;
      case 'uint':
        if (val < 0)
          throw new Error(`Negative value when uint expected while packing bit: ${bit}`);
        if (parseInt(val) != val)
          throw new Error(`Non-int value when uint expected while packing bit: ${bit}`);
        let valBytes = [];
        while (val) {
          valBytes.push(String.fromCharCode(val & 0xFF));
          val = val >> 8;
        }
        packed = valBytes.reverse().join('');
        if (len % 8 != 0)
          throw new Error(`Invalid number of target bits in bit: ${bit}`);
        len = len / 8;
        break;
      default:
        throw new Error(`Invalid pack type while packing bit: ${bit}`);
    }
    if (packed.length > len)
      throw new Error(`Packed value too long while packing bit: ${bit}: ${packed.length} > ${len}`);
    res += '\x00'.repeat(len - packed.length);
    res += packed;
  }

  return res;
}

export default class Payment {
  channelId: string
  sender: string
  receiver: string
  nonce: number
  price: number
  value: number
  channelValue: number
  nonce: number
  v: number
  r: string
  s: string

  constructor (options: PaymentJSON) {
    this.channelId = options.channelId
    this.sender = options.sender
    this.receiver = options.receiver
    this.price = options.price
    this.value = options.value
    this.channelValue = options.channelValue
    this.nonce = options.nonce
    this.v = Number(options.v)
    this.r = options.r
    this.s = options.s
  }

  static isValid (web3: Web3, payment: Payment, paymentChannel: PaymentChannel): Promise<boolean> {
    let basicChecks = [
        // Can't over-spend the channel
        (paymentChannel.spent + payment.price) <= paymentChannel.value,

        // Payment is being sent to the correct channel
        paymentChannel.channelId === payment.channelId,
        paymentChannel.sender === payment.sender,

        // Payment doesn't over-spend the channel
        paymentChannel.value <= payment.channelValue,

        // Value isn't negative
        payment.value >= 0 && payment.price >= 0,
    ];

    for (let i = 0; i < basicChecks.length; i += 1) {
        if (!basicChecks[i])
            return Promise.resolve(false);
    }

    let hash = ethHash(payment.getSignedBytes(
      1, // hard-code the chain ID
      getContractHash(), // I'm not sure off the top of my head how to grab this
    ));

    let signatureIsValid = (sender === ecrecover(hash, payment.v, payment.r, payment.s));

    return Promise.resolve(signatureIsValid);
  }

  function getSignedBytes (chainId: int, contractAddress: string): string {
    return pack(
      ['uint', 32, chainId],
      ['hex', 20, contractAddress],
      ['hex', 32, this.channelId],
      ['uint', 32, this.nonce],
      ['uint', 256, this.value],
    );
  }

  /**
   * Build {Payment} based on PaymentChannel and monetary value to send.
   */
  static fromPaymentChannel (web3: Web3, paymentChannel: PaymentChannel, price: number, override?: boolean): Promise<Payment> {
    let value = price + paymentChannel.spent
    if (override) { // FIXME
      value = paymentChannel.spent
    }
    let paymentDigest = digest(paymentChannel.channelId, value)
    return sign(web3, paymentChannel.sender, paymentDigest).then(signature => {
      let nonce = (paymentChannel.nonce || randomNonce()) + 1
      return new Payment({
        channelId: paymentChannel.channelId,
        sender: paymentChannel.sender,
        receiver: paymentChannel.receiver,
        price,
        value,
        channelValue: paymentChannel.value,
        nonce: nonce,
        v: signature.v,
        r: '0x' + signature.r.toString('hex'),
        s: '0x' + signature.s.toString('hex')
      })
    })
  }
}
