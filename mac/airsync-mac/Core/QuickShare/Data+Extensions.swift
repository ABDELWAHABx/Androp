//
//  Data+URLSafeBase64.swift
//  NearDrop
//
//  Created by Grishka on 08.04.2023.
//

import Foundation
import CoreFoundation
import Security

extension Data{
	func urlSafeBase64EncodedString() -> String {
		return String(base64EncodedString().replacingOccurrences(of: "=", with: "").map {
			if $0=="/"{
				return "_"
			} else if $0=="+" {
				return "-"
			} else {
				return $0
			}
		})
	}
	
	func suffixOfAtMost(numBytes:Int) -> Data{
		if count<=numBytes{
			return self;
		}
		return subdata(in: count-numBytes..<count)
	}
	
	static func randomData(length: Int) throws -> Data{
		guard length >= 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecParam)) }
		guard length > 0 else { return Data() }
		var data=Data(count: length)
		let status = data.withUnsafeMutableBytes {
			SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!)
		}
		guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
		return data
	}
	
	static func dataFromUrlSafeBase64(_ str:String)->Data?{
		var regularB64=String(str.map{
			if $0=="_"{
				return "/"
			}else if $0=="-"{
				return "+"
			}else{
				return $0
			}
		})
		while (regularB64.count%4) != 0{
			regularB64=regularB64+"="
		}
		return Data(base64Encoded: regularB64, options: .ignoreUnknownCharacters)
	}
}
