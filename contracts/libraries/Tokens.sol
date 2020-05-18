// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.8;
pragma experimental ABIEncoderV2;

import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {
  SafeMath as SafeMath256
} from '@openzeppelin/contracts/math/SafeMath.sol';

import { Structs } from './Interfaces.sol';
import { Transfers } from './Transfers.sol';


library Tokens {
  using SafeMath256 for uint256;

  struct Storage {
    mapping(address => Structs.Token) tokensByAddress;
    // The same symbol can be re-used for a different token
    mapping(string => Structs.Token[]) tokensBySymbol;
  }

  // Registration //

  function registerToken(
    Storage storage self,
    address tokenAddress,
    string memory symbol,
    uint8 decimals
  ) internal {
    require(
      !self.tokensByAddress[tokenAddress].isConfirmed,
      'Registration of this token is already finalized'
    );
    require(decimals <= 18, 'Decimals cannot exceed 18');
    self.tokensByAddress[tokenAddress] = Structs.Token({
      exists: true,
      tokenAddress: tokenAddress,
      symbol: symbol,
      decimals: decimals,
      isConfirmed: false,
      confirmedAt: 0
    });
  }

  function confirmTokenRegistration(
    Storage storage self,
    address tokenAddress,
    string memory symbol,
    uint8 decimals
  ) internal {
    Structs.Token memory token = self.tokensByAddress[tokenAddress];
    require(token.exists, 'Unknown token');
    require(
      !token.isConfirmed,
      'Registration of this token is already finalized'
    );
    require(isStringEqual(token.symbol, symbol), 'Symbols do not match');
    require(token.decimals == decimals, 'Decimals do not match');

    token.isConfirmed = true;
    token.confirmedAt = uint64(block.timestamp * 1000); // Block timestamp is seconds, store ms
    self.tokensByAddress[tokenAddress] = token;
    self.tokensBySymbol[symbol].push(token);
  }

  /**
   * @dev Resolves a token symbol into corresponding asset address
   *
   * @param symbol Token symbol, e.g. 'IDEX'
   * @param timestamp Milliseconds since Unix epoch, usually parsed from a UUID v1 order nonce.
   * Constrains symbol resolution to the token most recently confirmed prior to timestamp. Reverts
   * if no such token exists
   */
  function getAddressForSymbol(
    Storage storage self,
    string memory symbol,
    uint64 timestamp
  ) internal view returns (address) {
    return getTokenForSymbol(self, symbol, timestamp).tokenAddress;
  }

  /**
   * @dev Resolves a token symbol into corresponding Token struct
   *
   * @param symbol Token symbol, e.g. 'IDEX'
   * @param timestamp Milliseconds since Unix epoch, usually parsed from a UUID v1 order nonce.
   * Constrains symbol resolution to the token most recently confirmed prior to timestamp. Reverts
   * if no such token exists
   */
  function getTokenForSymbol(
    Storage storage self,
    string memory symbol,
    uint64 timestamp
  ) internal view returns (Structs.Token memory) {
    Structs.Token memory token;
    if (isStringEqual('ETH', symbol)) {
      token = Structs.Token(true, address(0x0), 'ETH', 18, true, 0);
    } else if (self.tokensBySymbol[symbol].length > 0) {
      for (uint8 i = 0; i < self.tokensBySymbol[symbol].length; i++) {
        if (self.tokensBySymbol[symbol][i].confirmedAt <= timestamp) {
          token = self.tokensBySymbol[symbol][i];
        }
      }
    }
    require(token.exists, 'No confirmed token found for symbol');

    return token;
  }

  function pipsToTokenQuantity(
    Storage storage self,
    uint64 quantityInPips,
    address tokenAddress
  ) internal view returns (uint256 tokenQuantity) {
    if (tokenAddress == address(0x0)) {
      return pipsToTokenQuantity(quantityInPips, 18);
    }

    Structs.Token memory token = self.tokensByAddress[tokenAddress];
    require(
      token.exists && token.isConfirmed,
      'No confirmed token found for address'
    );

    return pipsToTokenQuantity(quantityInPips, token.decimals);
  }

  function pipsToTokenQuantity(uint64 quantityInPips, uint64 tokenDecimals)
    internal
    pure
    returns (uint256)
  {
    if (tokenDecimals > 8) {
      return quantityInPips * uint256(10)**(tokenDecimals - 8);
    }
    return quantityInPips / uint256(10)**(8 - tokenDecimals);
  }

  function tokenQuantityToPips(uint256 tokenQuantity, uint256 tokenDecimals)
    internal
    pure
    returns (uint64)
  {
    uint256 quantityInPips;
    if (tokenDecimals > 8) {
      quantityInPips = tokenQuantity / uint256(10)**(tokenDecimals - 8);
    } else {
      quantityInPips = tokenQuantity * uint256(10)**(8 - tokenDecimals);
    }
    require(quantityInPips < 2**64, 'Pip quantity overflows uint64');

    return uint64(quantityInPips);
  }

  function transferFromWallet(
    Storage storage self,
    address payable wallet,
    address tokenAddress,
    uint256 tokenQuantity
  ) internal returns (uint64 quantityInPips) {
    if (tokenAddress == address(0x0)) {
      quantityInPips = tokenQuantityToPips(tokenQuantity, 18);
    } else {
      quantityInPips = tokenQuantityToPips(
        tokenQuantity,
        self.tokensByAddress[tokenAddress].decimals
      );
    }
    require(quantityInPips > 0, 'Quantity is too low');

    // If the asset is ETH then the funds were already sent via msg.value and no further steps are
    // needed. Otherwise, call the transferFrom function on the token contract for the pre-approved
    // amount
    if (tokenAddress != address(0x0)) {
      // Convert back to token qty to prevent transferring fractions of pips
      uint256 tokenQuantityInPipPrecision = pipsToTokenQuantity(
        quantityInPips,
        self.tokensByAddress[tokenAddress].decimals
      );
      Transfers.transferFrom(wallet, tokenAddress, tokenQuantityInPipPrecision);
    }

    return quantityInPips;
  }

  // See https://solidity.readthedocs.io/en/latest/types.html#bytes-and-strings-as-arrays
  function isStringEqual(string memory a, string memory b)
    internal
    pure
    returns (bool)
  {
    return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
  }
}
