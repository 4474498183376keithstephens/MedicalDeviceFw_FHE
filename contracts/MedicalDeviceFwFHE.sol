// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract MedicalDeviceFwFHE is SepoliaConfig {
    struct EncryptedFirmware {
        uint256 id;
        euint32 encryptedFirmwareData;
        euint32 encryptedCommands;
        uint256 timestamp;
    }

    struct DecryptedFirmware {
        string firmwareData;
        string commands;
        bool isDecrypted;
    }

    uint256 public firmwareCount;
    mapping(uint256 => EncryptedFirmware) public encryptedFirmwares;
    mapping(uint256 => DecryptedFirmware) public decryptedFirmwares;

    mapping(string => euint32) private encryptedCommandCount;
    string[] private commandCategories;

    mapping(uint256 => uint256) private requestToFirmwareId;

    event FirmwareSubmitted(uint256 indexed id, uint256 timestamp);
    event DecryptionRequested(uint256 indexed id);
    event FirmwareDecrypted(uint256 indexed id);

    modifier onlyOperator(uint256 firmwareId) {
        _;
    }

    function submitEncryptedFirmware(
        euint32 encryptedFirmwareData,
        euint32 encryptedCommands
    ) public {
        firmwareCount += 1;
        uint256 newId = firmwareCount;

        encryptedFirmwares[newId] = EncryptedFirmware({
            id: newId,
            encryptedFirmwareData: encryptedFirmwareData,
            encryptedCommands: encryptedCommands,
            timestamp: block.timestamp
        });

        decryptedFirmwares[newId] = DecryptedFirmware({
            firmwareData: "",
            commands: "",
            isDecrypted: false
        });

        emit FirmwareSubmitted(newId, block.timestamp);
    }

    function requestFirmwareDecryption(uint256 firmwareId) public onlyOperator(firmwareId) {
        EncryptedFirmware storage fw = encryptedFirmwares[firmwareId];
        require(!decryptedFirmwares[firmwareId].isDecrypted, "Already decrypted");

        bytes32[] memory ciphertexts = new bytes32[](2);
        ciphertexts[0] = FHE.toBytes32(fw.encryptedFirmwareData);
        ciphertexts[1] = FHE.toBytes32(fw.encryptedCommands);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptFirmware.selector);
        requestToFirmwareId[reqId] = firmwareId;

        emit DecryptionRequested(firmwareId);
    }

    function decryptFirmware(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 firmwareId = requestToFirmwareId[requestId];
        require(firmwareId != 0, "Invalid request");

        EncryptedFirmware storage eFw = encryptedFirmwares[firmwareId];
        DecryptedFirmware storage dFw = decryptedFirmwares[firmwareId];
        require(!dFw.isDecrypted, "Already decrypted");

        FHE.checkSignatures(requestId, cleartexts, proof);

        string[] memory results = abi.decode(cleartexts, (string[]));
        dFw.firmwareData = results[0];
        dFw.commands = results[1];
        dFw.isDecrypted = true;

        if (!FHE.isInitialized(encryptedCommandCount[results[1]])) {
            encryptedCommandCount[results[1]] = FHE.asEuint32(0);
            commandCategories.push(results[1]);
        }
        encryptedCommandCount[results[1]] = FHE.add(
            encryptedCommandCount[results[1]],
            FHE.asEuint32(1)
        );

        emit FirmwareDecrypted(firmwareId);
    }

    function getDecryptedFirmware(uint256 firmwareId) public view returns (
        string memory firmwareData,
        string memory commands,
        bool isDecrypted
    ) {
        DecryptedFirmware storage fw = decryptedFirmwares[firmwareId];
        return (fw.firmwareData, fw.commands, fw.isDecrypted);
    }

    function getEncryptedCommandCount(string memory category) public view returns (euint32) {
        return encryptedCommandCount[category];
    }

    function requestCommandCountDecryption(string memory category) public {
        euint32 count = encryptedCommandCount[category];
        require(FHE.isInitialized(count), "Category not found");

        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(count);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptCommandCount.selector);
        requestToFirmwareId[reqId] = bytes32ToUint(keccak256(abi.encodePacked(category)));
    }

    function decryptCommandCount(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 categoryHash = requestToFirmwareId[requestId];
        string memory category = getCategoryFromHash(categoryHash);

        FHE.checkSignatures(requestId, cleartexts, proof);

        uint32 count = abi.decode(cleartexts, (uint32));
    }

    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }

    function getCategoryFromHash(uint256 hash) private view returns (string memory) {
        for (uint i = 0; i < commandCategories.length; i++) {
            if (bytes32ToUint(keccak256(abi.encodePacked(commandCategories[i]))) == hash) {
                return commandCategories[i];
            }
        }
        revert("Category not found");
    }
}
