//
//  Networking.swift
//  WebDE
//
//  Created by Karim Alweheshy on 2/11/19.
//  Copyright © 2019 Karim Alweheshy. All rights reserved.
//

import UIKit
import Networking

final class Networking: NetworkingType {
    public let registeredModules: [ModuleType.Type]
    public var inMemoryModule = [ModuleType]()
    
    fileprivate var presentationBlock: (UIViewController) -> Void
    fileprivate var dismissBlock: (UIViewController) -> Void
    
    fileprivate let remoteHost = "google"
    fileprivate var urlSession: URLSession
    fileprivate var isAuthorized = false
    
    public init(modules: [ModuleType.Type],
                presentationBlock: @escaping (UIViewController) -> Void,
                dismissBlock: @escaping (UIViewController) -> Void,
                configuration: URLSessionConfiguration = .default) {
        self.registeredModules = modules
        self.presentationBlock = presentationBlock
        self.dismissBlock = dismissBlock
        urlSession = URLSession(configuration: configuration)
    }
    
    public func execute<T>(request: InternalRequest,
                           presentationBlock: @escaping (UIViewController) -> Void,
                           dismissBlock: @escaping (UIViewController) -> Void,
                           completionHandler: @escaping (Result<T>) -> Void) {
        
        let canHandleModules = registeredModules.filter {
            let hasCapability = $0.capabilities.contains { $0 == type(of: request) }
            let hasCorrectResponseType = T.self == type(of: request).responseType
            return hasCapability && hasCorrectResponseType
        }
        
        guard !canHandleModules.isEmpty else {
            completionHandler(.error(ResponseError.badRequest400(error: nil)))
            return
        }
        
        let completionBlock = { (module: ModuleType, result: Result<T>) in
            self.inMemoryModule.removeAll { $0 === module }
            completionHandler(result)
        }
        
        canHandleModules.forEach { Module in
            let module = Module.init(presentationBlock: presentationBlock, dismissBlock: dismissBlock)
            module.execute(networking: self, request: request) { (result: Result<T>) in
                switch result {
                case .success: completionBlock(module, result)
                case .error(let error):
                    guard let error = error as? ResponseError else {
                        completionBlock(module, result)
                        return
                    }
                    let retryBlock = { (canRetry: Bool) in
                        guard canRetry else {
                            completionBlock(module, result)
                            return
                        }
                        self.execute(request: request,
                                     presentationBlock: presentationBlock,
                                     dismissBlock: dismissBlock,
                                     completionHandler: { completionBlock(module, $0) })
                    }
                    switch error.errorCode {
                    case 401: self.handleUnauthorized(completionHandler: retryBlock)
                    case 403: self.handleForbidden(completionHandler: retryBlock)
                    default: completionBlock(module, result)
                    }
                }
            }
            inMemoryModule.append(module)
        }
    }
    
    public func execute<T: Codable>(request: RemoteRequest,
                                    completionHandler: @escaping (Result<T>) -> Void) {
        if !isAuthorized {
            self.handleUnauthorized { success in
                if success {
                    self.execute(request: request, completionHandler: completionHandler)
                } else {
                    completionHandler(.error(ResponseError.unauthorized401(error: nil)))
                }
            }
            return
        }
        urlSession.dataTask(with: request.urlRequest(from: remoteHost)) { (data, urlResponse, error) in
            var apiError: Error?
            var apiResult: T?

            //Authorize and re-login
            if let urlResponse = urlResponse as? HTTPURLResponse {
                switch urlResponse.statusCode {
                case 200...300:
                    guard let data = data,
                        let contentType = urlResponse.allHeaderFields["Content-Type"] as? String,
                        contentType == "application/json" else {
                            return
                    }
                    do {
                        apiResult = try JSONDecoder().decode(T.self, from: data)
                    } catch let parsingError {
                        apiError = parsingError
                    }
                case 401, 403:
                    let retryBlock = { (canRetry: Bool, responseError: ResponseError) in
                        DispatchQueue.main.async {
                            guard canRetry else {
                                completionHandler(.error(responseError))
                                return
                            }
                            self.execute(request: request, completionHandler: completionHandler)
                        }
                    }
                    if urlResponse.statusCode == 401 {
                        self.handleUnauthorized { retryBlock($0, .unauthorized401(error: nil))}
                    } else if urlResponse.statusCode == 403 {
                        self.handleForbidden { retryBlock($0, .forbidden403(error: nil))}
                    }
                    return
                default: apiError = error
                }
            }
        
            DispatchQueue.main.async {
                if let apiResult = apiResult {
                    completionHandler(.success(apiResult))
                    return
                }
                completionHandler(.error(apiError ?? error ?? ResponseError.other))
            }
        }.resume()
    }
}

extension Networking {
    fileprivate func handleUnauthorized(completionHandler: @escaping (Bool) -> Void) {
        // Authorize and re-login
        let requestBody = ExplicitLoginRequestBody(email: nil, password: nil)
        let authRequest = ExplicitLoginRequest(data: requestBody)
        self.execute(request: authRequest,
                     presentationBlock: self.presentationBlock,
                     dismissBlock: self.dismissBlock) { (result: Result<AuthenticationResponse>) in
            switch result {
            case .success(let authentication):
                self.isAuthorized = true
                self.updateSession(authToken: authentication.authToken)
                completionHandler(true)
            case .error:
                self.isAuthorized = false
                completionHandler(false)
            }
        }
    }
    
    fileprivate func handleForbidden(completionHandler: @escaping (Bool) -> Void) {
    }
    
    fileprivate func updateSession(authToken: String) {
        let configuration = self.urlSession.configuration
        var headers = configuration.httpAdditionalHeaders ?? [AnyHashable: Any]()
        headers["Authorization"] = "Bearer \(authToken)"
        configuration.httpAdditionalHeaders = headers
        self.urlSession = URLSession(configuration: configuration)
    }
}
