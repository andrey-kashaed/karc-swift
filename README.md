# karc-swift

***Karc*** is a library simplifying architectural program design in Swift.

[![Latest Release](https://img.shields.io/badge/Latest%20Release-0.1.1-green)](https://github.com/andrey-kashaed/karc-swift/releases/tag/0.1.1)
[![Swift](https://img.shields.io/badge/Swift-5.8-yellow)](https://www.swift.org/blog/swift-5.8-released)
![Platforms](https://img.shields.io/badge/Platforms-macOS%2013.0%2B%20%7C%20iOS%2016.0%2B%20%7C%20tvOS%2016.0%2B%20%7C%20watchOS%209.0%2B-red)
[![License](https://img.shields.io/badge/License-CDDL--1.0-blue)](https://opensource.org/licenses/CDDL-1.0)

# Installation

The [Swift Package Manager](https://swift.org/package-manager/) automates the distribution of Swift code. To use ***Karc*** with SPM, add a dependency to `https://github.com/andrey-kashaed/karc-swift.git`

# Documentation

***Karc*** library is based on [***Kasync*** library](https://github.com/andrey-kashaed/kasync-swift) and provides several components to help with implemention of application's business logic.

* [`Model`](#model): encapsulates all business logic related with specific *domain*.
* [`Domain`](#domain): specifies single entry point for communication with *model* from other application layers.
* [`Interactor`](#interactor): specifies single entry point for communication with *model* from *model's* *pipelines*.
* [`Environ`](#environ): provides *resource dependencies*.
* [`Pipeline`](#pipeline): contains collection of independent *pipes* in order to implement specific application feature.
* [`Pipe`](#pipe): describes execution flow including side effects and communication with *model* by means of *interactors*.

Key features of this library are:

* Single source of truth
* Unidirectional data flow
* Scalability
* Functional purity
* Testability

##### Single source of truth

Every [`Model`](#model) coupled with its [`Domain`](#domain) has single source of truth backed by one `state` property of generic `State` type. This property may be changed only by means of result from [`reducer`](#model_reducer), which must be overriden in all subclasses of [`Model`](#model) class.

> **Warning**: every overriden [`reducer`](#model_reducer) must remain as pure function without any side effects!

##### Unidirectional data flow

Every [`Model`](#model) coupled with its [`Domain`](#domain) provides only one data flow way.

1. Application subsystem (such as view layer) can use [`Domain`](#domain)'s [`send`](#domain_send) method in order to send *command* to the *command drain*.
2. Specific [`Pipe`](#pipe) from [`Pipeline`](#pipeline) can use [`Interactor`](#interactor)'s [`commandSource`](#interactor_command_source) property in order to receive *command* from *command source* for further processing. While processing [`Pipe`](#pipe) can perform different side effects and also use [`Interactor`](#interactor)'s [`effectDrain`](#interactor_command_source) property in order to send *effects* to *effect drain*. [`Pipe`](#pipe) can use [`Interactor`](#interactor)'s [`commandDrain`](#interactor_command_drain) property in order to send *command* to *command drain*.
3. [`Model`](#model)'s [`reducer`](#model_reducer) will receive *effects* from *effect source* and will generate new *state* and *events* which will be sent to *event drain*.
4. [`Domain`](#domain)'s overridden [`observe`](#domain_observe) method will receive new *state*, so public part of this state can be assigned to [`Domain`](#domain)'s observable properties.
5. Application subsystem (such as view layer) can use [`Domain`](#domain)'s observable properties in order to see *state* changes, and use [`Domain`](#domain)'s [`receiver`](#domain_receiver) method in order to receive *events* from *event source*.
6. Specific [`Pipe`](#pipe) from [`Pipeline`](#pipeline) can use [`Interactor`](#interactor)'s [`eventSource`](#interactor_event_source) property in order to receive *event* from *event source* for further processing.

> **Warning**: despite the fact that you can use any `Sendable` type as `State`, `Command`, `Effect` and `Event`, it's highly recommended to use Swift value types in order to comply with thread safety and prevent race conditions.

##### Scalability

Application may be scaled to have any number of [`Model`](#model) subtypes (and corresponding [`Domain`](#domain) subtypes) you need. You can maintain relationship between all *models* in a structural way by means of [*scoping*](#model_scopes) mechanism. Every [`Model`](#model) can have any number of [`Scope`](#scope)s.

##### Functional purity

Library is designed to facilitate usage of [pure functions](https://en.wikipedia.org/wiki/Pure_function) without side effects that help to reduce the amount of errors. You can easily use only pure functions in order to describe [`Model`](#model), its [`Scope`](#scope)s and [`Pipeline`](#pipeline)s.

> **Note**: one reasonable place to use impure function is when you override [`Domain`](#domain)'s [`observe`](#domain_observe) method in order to propagate *state* changes to [`Domain`](#domain)'s public observable properties.

##### Testability

Library makes extensive use of Swift's [async/await](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html) mechanism so you can easily implement complex test cases in several lines of code, see [sample](#step_6).

### Usage

#### <a id="step_1"></a> Step 1: Domain definition ####

At first we need to define [`Domain`](#domain) subclass describing its *state*, *commands* and *events*.

```swift
struct TestState: Equatable, Initable {
    var account: Account? = nil
}

protocol TestCommand {}

struct RegisterAccount: TestCommand {
    let userEmail: String
    let userPassword: String
}

struct UnregisterAccount: TestCommand {}

struct DispatchOutgoingMessage: TestCommand {
    let message: DecryptedMessage
}

protocol TestEvent {}

struct UpdatedAccount: TestEvent, Equatable {
    let account: Account
}

struct DeletedAccount: TestEvent {
    let account: Account
}

@Observable
final class TestDomain: Domain<DefaultId, TestState, TestCommand, TestEvent> {
    
    private(set) var account: Account?
    
    required init(id: DefaultId, state: TestState) {
        account = state.account
        super.init(id: id, state: state)
    }
    
    override func observe(state: TestState) {
        account = state.account
    }
    
}
```

#### <a id="step_2"></a> Step 2: Model definition ####

When [`reducer`](#model_reducer) receives `updatingAccount` *effect* it will set *state*'s `account` property to not `nil` value. In this case corresponding *scope* will be *active* and its `messaging` *pipeline* will start execution. When [`reducer`](#model_reducer) receives `deletingAccount` *effect* it will set *state*'s `account` property to `nil` value. In this case corresponding *scope* will be *inactive* and its `messaging` *pipeline* will stop execution.

```swift
enum TestEffect {
    case updatingAccount(_ account: Account)
    case deletingAccount
}

class TestModel: Model<TestDomain, DefaultId, TestState, TestCommand, TestEffect, TestEvent> {
    
    override var loggerEnabled: Bool {
        true
    }
    
    override func reducer(state: TestState, effect: TestEffect) -> (TestState, [TestEvent]) {
        switch effect {
        case .updatingAccount(let account):
            if state.account == account {
                return (state, [])
            }
            var newState = state
            newState.account = account
            return (newState, [UpdatedAccount(account: account)])
        case .deletingAccount:
            if let account = state.account {
                var newState = state
                newState.account = nil
                return (newState, [DeletedAccount(account: account)])
            }
            return (state, [])
        }
    }
    
    @ScopesBuilder
    override func scopes(_ s: TestState, _ i: Interactor) -> [Scope] {
        ChildModel.submodel()
        Injector<StorageResource>()
        i.main // will be defined in next step
        if s.account != nil {
            i.messaging // will be defined in next step
        }
    }
    
}
```

#### <a id="step_3"></a> Step 3: Pipeline definition ####

Every [`Model`](#model) has own [`Interactor`](#interactor) which is passed as closure parameter to `scopes` factory method. All [`Pipeline`](#pipeline) factory methods should be added with [`Interactor`](#interactor)'s extension, so future [`Pipeline`](#pipeline) may have access to [`Interactor`](#interactor)'s public interface in order to communicate with the [`Model`](#model).

```swift
fileprivate extension TestModel.Interactor {

    func main() -> Pipeline {
        @Inject<StorageResource, DefaultId>(environ) var storage
        @Use<WebResource, DefaultId>(environ) var web
        return Pipeline {
            Pipe(id: "bootstrap", policy: .finite(count: 1)) { _, context in
                if let account = await storage.readAccount() {
                    context.logInfo("Restored account: \(account)")
                    try await sendEffects(.updatingAccount(account))
                } else {
                    ontext.logInfo("No stored account")
                }
            }
            Pipe(
                id: "register-account",
                mode: .duplex(),
                source: commandSource
            ) { (command: RegisterAccount, context: PipeContext) -> Result<Account, Error> in
                if await state.account != nil {
                    throw RuntimeError("Account is already registered!")
                }
                let account = try await web.register(
                    userEmail: command.userEmail, 
                    userPassword: command.userPassword)
                await storage.saveAccount(account)
                context.logInfo("Account is registered")
                let events = try await effectDrain.send([.updatingAccount(account)])
                if let event = events.first as? UpdatedAccount {
                    return .success(event.account)
                } else {
                    return .failure(AccountAlreadyRegisteredError())
                }
            }
            Pipe(
                id: "unregister-account",
                mode: .simplex(),
                source: commandSource
            ) { (command: UnregisterAccount, context: PipeContext) in
                guard let account = await state.account else {
                    throw RuntimeError("Account is already unregistered!") 
                }
                await storage.deleteAccount()
                try await sendEffects(.deletingAccount)
                try await web.unregister(account: account)
                context.logInfo("Account is unregistered")
            }
            Pipe(id: "updated-account", mode: .simplex(), source: eventSource) { (event: UpdatedAccount, context: PipeContext) in
                context.logInfo("Account is updated")
            }
            Pipe(id: "deleted-account", mode: .simplex(), source: eventSource) { (event: DeletedAccount, context: PipeContext) in
                context.logInfo("Account is deleted")
            }
        }
    }
    
}
```
As we can see from code above, we used `@Inject` and `@Use` property wrappers in order to resolve our dependencies, see [important details](#note_inject) about `@Inject` property wrapper and [important details](#note_use) about `@Use` property wrapper. We defined `bootstrap` *pipe* which will be executed only once because we specified `policy: .finite(count: 1)`. Since we defined `main` factory method as a part of [`Interactor`](#interactor)'s extension, we have access to properties like `state`, `commandSource`, `commandDrain`, `effectDrain`, `eventSource`. We can use aforementioned *sources* and *drains* as `source` and `drain` parameters for *pipes*. We specified `mode: .duplex()` for `register-account` *pipe*. This means that call like `TestDomain.get.send(RegisterAccount(userEmail: <EMAIL>, userPassword: <PASSWORD>))` will return right after *pipe*'s *track* finishes its execution. We specified `mode: .simplex()` for `unregister-account` *pipe*. This means that call like `TestDomain.get.send(UnregisterAccount())` will return right before *pipe*'s *track* starts its execution. After we send `.updatingAccount` *effect* to `effectDrain` and [`Model`](#model)'s `reducer` changes *state* value returning `UpdatedAccount` *event* we will receive this event in `updated-account` *pipe*, so we can handle this event. The same way we can receive and handle `DeletedAccount` *event* in `deleted-account` *pipe*.

```swift
fileprivate extension TestModel.Interactor {

    func messaging() -> Pipeline {
        @Inject<StorageResource, DefaultId>(environ) var storage
        @Use<WebResource, DefaultId>(environ) var web
        let incomingMessageGate = Gate<EncryptedMessage, Void>(mode: .retainable(), scheme: .anycast)
        let outgoingMessageGate = Gate<EncryptedMessage, Void>(mode: .retainable(), scheme: .anycast)
        return Pipeline(
		     begin: { _, context in
                context.logInfo("start messaging...")
            },
            end: { _, context in
                context.logInfo("stop messaging...")
            }
        ) {
            for i in 1...6 {
                Pipe(
                    id: "dispatch-outgoing-message-\(i)",
                    mode: .duplex(),
                    source: commandSource,
                    drain: outgoingMessageGate
                ) { (command: DispatchOutgoingMessage, context: PipeContext) -> EncryptedMessage in
                    let decryptedMessage = command.message
                    let encryptedMessage: EncryptedMessage = try encryptMessage(decryptedMessage)
                    return encryptedMessage
                }
            }
            Pipe(
                id: "accept-incoming-message",
                mode: .simplex(),
                source: incomingMessageGate
            ) { (encryptedMessage: EncryptedMessage, context: PipeContext) async throws -> Void in
                let decryptedMessage = try decryptMessage(encryptedMessage)
                // handle decrypted incoming message
            }
            Pipe(
                id: "swap-encrypted-messages",
                mode: .simplex(
                    intro: { $0.collect(interval: .seconds(10)) },
                    outro: { $0.flatMap { iterate(elements: $0) }*! }
                ),
                source: outgoingMessageGate,
                drain: incomingMessageGate
            ) { outgoingMessages, context in
                guard let account = await state.account else {
                    throw RuntimeError("Account is not registered!")
                }
                let incomingMessages = try await web.swap(messages: outgoingMessages, account: account)
                return incomingMessages
            }
        }
    }
    
    private func encryptMessage(_ decryptedMessage: DecryptedMessage) throws -> EncryptedMessage {
        // implementation
    }
    
    private func decryptMessage(_ encryptedMessage: EncryptedMessage) throws -> DecryptedMessage {
        // implementation
    }

}
```

We defined two `Gate`s: `incomingMessageGate` and `outgoingMessageGate`. We are going to use them for communication between independent *pipes*. For `Gate` usage details see [***Kasync*** documentation](https://github.com/andrey-kashaed/kasync-swift/blob/main/README.md). [`Pipeline`](#pipeline) initializer uses [`@resultBuilder`](https://docs.swift.org/swift-book/LanguageGuide/AdvancedOperators.html#ID630) for [`Pipe`](#pipe)'s creation, so we can utilize its functionality and use *for* cycle to specify a certain amount of *pipes* with the same description. We defined six *pipes* consuming `DispatchOutgoingMessage`, which means that we can process six *commands* at the same time. So if we are going to execute seven calls like this `TestDomain.get.send(DispatchOutgoingMessage(message: ...))` only six of them will proceed execution while the seventh will throw error. By means of this technique we can specify *capacity* for certain *command* type. We use `incomingMessageGate` as *source* for `accept-incoming-message` *pipe* and as *drain* for `swap-encrypted-messages` *pipe*. Also we use `outgoingMessageGate` as *source* for `swap-encrypted-messages` *pipe* and as *drain* for `dispatch-outgoing-message-\(i)` *pipes*. For `swap-encrypted-messages` *pipe*'s `mode` parameter we specified `intro` and `outro` in order to transform *source* input to *track* input and to transform *track* output to *drain* input respectively.

#### <a id="step_5"></a> Step 5: Environ definition ####

Next we need to define *environ* object to provide necessary dependencies for the [`Model`](#model).

```swift
struct Environs {
    
    static let prod = Environ()
        .register(StorageResource.self, gatewayType: StorageProdGateway.self)
        .register(WebResource.self, gatewayType: WebProdGateway.self)
        // other dependencies
        
    static let test = Environ()
        .register(StorageResource.self, gatewayType: StorageTestGateway.self)
        .register(WebResource.self, gatewayType: WebTestGateway.self)
        // other dependencies
        
}
```

#### <a id="step_6"></a> Step 6: Test ####

In order to demonsrate testability let's test our account registration workflow.

```swift
final class Tests: XCTestCase {

    func testModel() async throws {
        // Creation of TestModel and corresponding TestDomain
        TestModel.setUp(TestModel.Config(environ: Environs.test))
        // Deferred destruction of TestModel and corresponding TestDomain
        defer { TestModel.tearDown() }
        // Obtain event receiver to use it later
        let eventReceiver = TestDomain.get.receiver()
        // Send account registration command waiting for result
        // Will get result only after "register-account" pipe returns result from its track
        let result = try await TestDomain.get.send(
            RegisterAccount(userEmail: "test@email.com", userPassword: "qwerty")
        ) as! Result<Account, Error>
        // Assert that proper account is registered
        switch result {
        case .success(let account): 
            XCTAssertEqual(account, Account(email: "test@email.com", password: "qwerty"))
        case .failure(let error): 
            XCTFail(error.localizedDescription)
        }
        let account = await TestDomain.get.state.account
        // Assert that state account is the same as expected
        XCTAssertEqual(account, Account(email: "test@email.com", password: "qwerty"))
        // We should receive the same event that was received inside "register-account" pipe
        for try await event in eventReceiver {
            // Assert that we received expected event with the same account
            XCTAssertEqual(
                event as? UpdatedAccount, 
                UpdatedAccount(account: Account(email: "test@email.com", password: "qwerty"))
            )
            break
        }
        // Send account registration command second time waiting for result
        let result2 = try await TestDomain.get.send(
            RegisterAccount(userEmail: "test@email.com", userPassword: "qwerty")
        ) as! Result<Account, Error>
        // Assert error saying that account is already registered
        switch result2 {
        case .success( _): 
            XCTFail("Account must be already registered, something went wrong!")
        case .failure(let error): 
            XCTAssertEqual(
                error.localizedDescription,
                AccountIsAlreadyRegisteredError().localizedDescription
            )
        }
    }
    
}
```

## <a id="model"></a> Model ##

`Model` encapsulates app's business logic based on *scopes*. Every `Model` object is coupled with corresponding [`Domain`](#domain) object which is only entry point for all communications with `Model` from outside. All models must be inherited from base `Model` class. `Model` class is generic, so it has several generic parameters: `Domain`, `State`, `Command`, `Effect`, `Event`.

---
<a id="model_set_up"></a>

```swift
public static func setUp(_ config: Config)
```
> Creates `Model` instance (together with corresponding [`Domain`](#domain) instance), adding them to the *internal pool*. Parameter `id` is an optional identifier. Parameter `config` specifies `environ` object, an optional `id` and an optional `state`.

---

```swift
public static func tearDown(id: Id = DefaultId.shared)
```
> Destroys `Model` instance (together with corresponding [`Domain`](#domain) instance), removing them from the *internal pool*.

---

```swift
required public init(config: Config)
```
> Creates an instance of `Model`. Should not be overridden by subclass and must not be called directly.

---

```swift
public let uid: String
```
> Returns unique identifier for `Model`.

---
<a id="model_reducer"></a>

```swift
open var reducer: Reducer
```
> This computed property is responsible for reducing `Effect` instances to the new `State` and `Event` instances. Must be overridden by subclass.

---
<a id="model_scopes"></a>

```swift
@ScopesBuilder
open func scopes(state: State, i: Interactor) -> [Scope]
```
> Returns `Model`'s [`Scope`](#scope) instances. Should be overridden by subclass. `Scope` describes behavior for certain subset of [`Model`](#model)'s *state*. If this method returns new `Scope` instance this *scope* becomes *active*. If this method does not return `Scope` instance which was previously *active*, this *scope* becomes *inactive*.
> 
> **Note**: you can specify different kinds of scopes like *submodels*, *resource injectors* and *pipelines*. So you can maintain structured relationship between all the models because *submodel* lifetime is going to be limited by lifetime of *scope's* *active* phase.
> 
> #### Sample:
> 
> ```swift
> class TestModel: Model<TestDomain, DefaultId, TestState, TestCommand, TestEffect, TestEvent> {
>     .........
>     @ScopesBuilder
>     override func scopes(_ s: TestState, _ i: Interactor) -> [Scope] {
>         ChildModel.submodel() // Submodel scope
>         Injector<StorageResource>() // Resource injector scope
>         i.main // pipeline scope
>         if s.account != nil {
>             i.messaging // another pipeline scope
>         }
>     }
>     .........
> }
> ```

---

```swift
open func onSetUp()
```
> Callback which is called on `Model` setup. May be overridden by subclass.

---

```swift
open func onTearDown()
```
> Callback which is called on `Model` teardown. May be overridden by subclass.

---

```swift
open func willReduce(state: State, effects: [Effect])
```
> Callback which is called before the old `state` and `effects` are reduced. May be overridden by subclass.

---

```swift
open func didReduce(state: State, events: [Event])
```
> Callback which is called after reducer returns the new `state` and `events`. May be overridden by subclass.

---

## <a id="domain"></a> Domain ##

`Domain` is facade, an entry point for all communication with [`Model`](#model) from outside (for example from *view* application layer). `Domain` class has several generic parameters: `Id`, `State`, `Command` and `Event`.

---

```swift
public static var get: Self { get async throws }
```
> Provides `Domain` instance specific for used subtype.

---

```swift
public static func get(id: Id) async throws -> Self
```
> Provides `Domain` instance specific for used subtype. Parameter `id` must match [`Model`](#model)'s id used during setup.

---

```swift
public static var getOrNil: Self? { get async }
```
> Provides `Domain` optional instance specific for used subtype.

---

```swift
public static func getOrNil(id: Id) async -> Self?
```
> Provides `Domain` optional instance specific for used subtype. Parameter `id` must match [`Model`](#model)'s id used during setup.

---

```swift
public static var getOrDefault: Self { get async }
```
> Provides `Domain` instance specific for used subtype if it exists, default instance otherwise.

---

```swift
public static func getOrDefault(id: Id) async -> Self
```
> Provides `Domain` instance specific for used subtype if it exists, default instance otherwise. Parameter `id` must match [`Model`](#model)'s id used during setup.

---

```swift
public var state: State { get async }
```
> Returns `state` instance.

---

```swift
public required init(id: Id, state: State)
```
> Creates an instance of `Domain`. Must be overridden by subclass but must not be called directly.

---
<a id="domain_observe"></a>

```swift
open func observe(state: State)
```
> Observes `State` changes. Should be overridden by subclass.

---
<a id="domain_send"></a>

```swift
public final func send(_ command: Command) async throws -> Any 
```
> Sends `Command` instance to the *command gate*. Returns `Any` instance.

---

```swift
public final func sendDetached(priority: TaskPriority? = Task.currentPriority, _ command: Command) -> Task<Any?, Never>
```
> Sends `Command` instance to the *command gate* as detached async task. Returns `Task<Any?, Never>` instance.

---

```swift
public final func receive() async throws -> Event
```
> Receives and returns `Event` instance from the *event gate*.

---

```swift
public final func receive<SubEvent>() async throws -> SubEvent
```
> Receives and returns `SubEvent` instance from the *event gate*.

---
<a id="domain_receiver"></a>

```swift
public func receiver() -> AsyncThrowingStream<Event, Error>
```
> Returns `AsyncThrowingStream<Event, Error>` receiver which may receive `Event` instances from the *event gate*.

---

```swift
public func receiver<SubEvent>() -> AsyncThrowingStream<SubEvent, Error>
```
> Returns `AsyncThrowingStream<SubEvent, Error>` receiver which may receive `SubEvent` instances from the *event gate*.

---

```swift
public final var commandDrain: some Drain<Command, Any>
```
> Returns *command drain*.

---

```swift
public final var eventSource: some Source<Event, Void>
```
> Returns *event source*.

---

## <a id="interactor"></a> Interactor ##

`Interactor` is facade for interaction with [`Model`](#model) from inside of [`Pipeline`](#pipeline)s. `Interactor` exposes *command drain*, *command source*, *effect drain*, and *event source*. It's necessary to define *pipeline* factory methods as `Interactor`'s extension methods.

---

```swift
public var state: State { get async }
```
> Returns [`Model`](#model)'s state.

---
<a id="interactor_command_drain"></a>

```swift
public var commandDrain: some Drain<Command, Any>
```
> Returns *command drain*.

---
<a id="interactor_command_source"></a>

```swift
public var commandSource: some Source<Command, Any>
```
> Returns *command source*.

---
<a id="interactor_effect_drain"></a>

```swift
public var effectDrain: some Drain<[Effect], [Event]>
```
> Returns *effect drain*.

---
<a id="interactor_event_source"></a>

```swift
public var eventSource: some Source<Event, Void>
```
> Returns *event source*.

---

## <a id="environ"></a> Environ ##

`Environ` encapsulates application *resource dependencies*.

---

```swift
public func register<R, G: Resource>(_ resourceType: R.Type, gatewayType: G.Type) -> Environ
```
> Registers *resource dependency* of type `R` with *gateway implementation* of type `G`.

---

```swift
public func register<R>(acquire: @Sendable @escaping ([String: Any]) async throws -> R, release: @Sendable @escaping (R) async throws -> Void) -> Environ
```
> Registers *resource dependency* of type `R`.

---

```swift
public func resolve<R, Id: Equatable & Hashable & Sendable>(id: Id = DefaultId.shared) async throws -> R
```
> Resolves *resource dependency* of type `R` with `id` of type `Id`.

---

```swift
public func resolve<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws -> R
```
> Resolves *resource dependency* of type `R` with `id` of type `Id`.

---

```swift
public func acquire<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws
```
> Acquires *resource dependency* of type `R` with `id` of type `Id`.

---

```swift
public func release<R, Id: Equatable & Hashable & Sendable>(_ resourceType: R.Type, id: Id = DefaultId.shared) async throws
```
> Releases *resource dependency* of type `R` with `id` of type `Id`.

---

You can take advantage of `Inject` *property wrapper* in order to inject *resource dependency*.

```swift
@Inject<StorageResource, DefaultId>(environ) var storage
```

> <a id="note_inject"></a>
> 
> **Note**: `@Inject` property wrapper provides [dependency injection](https://en.wikipedia.org/wiki/Dependency_injection) mechanism. It means that *resource dependency* will be injected if you already have active corresponding `Injector<StorageResource>` scope.

You can also take advantage of `Use` *property wrapper* in order to use *resource dependency* on demand.

```swift
@Use<WebResource, DefaultId>(environ) var web
```

> <a id="note_use"></a>
> 
> **Note**: `@Use` property wrapper provides [RAII](https://en.wikipedia.org/wiki/Resource_acquisition_is_initialization) mechanism. It means that *resource dependency* will be acquired on first usage of `web` variable and will be released during variable deinitialization.

## <a id="pipeline"></a> Pipeline ##

`Pipeline` is a collection of independent *pipes*.

---

```swift
public init(
    tag: String = #function,
    id: Id = DefaultId.shared,
    begin: PipeTrack<Void, Void>? = nil,
    end: PipeTrack<Void, Void>? = nil,
    @PipeBuilder pipes: @escaping () -> [Pipe])
```
> Creates an instance of `Pipeline`. Parameter `begin` defines block of code which will be executed before all *pipes* defined in `pipesFactory` starts execution. Parameter `end` defines block of code which will be executed after all *pipes* defined in `pipes` stops execution. Parameter `pipes` defines collection of independent [`Pipe`](#pipe) instances.

---

## <a id="pipe"></a> Pipe ##

`Pipe` encapsulates all behavioral logic of application including side effects, consumption and handling of *commands* and *events*, production and dispatching of *effects* and *commands*.

---

```swift
public init<SI, SO, TI, TO, DI, DO>(
    id: String,
    recoverFromError: Bool = true,
    mode: Mode<SI, SO, TI, TO, DI, DO>,
    source: any Source<SI, SO>,
    drain: any Drain<DI, DO>,
    track: @escaping PipeTrack<TI, TO>
```

> Creates an instance of `Pipe`. 

#### Parameters:

##### id

> It is *pipe*'s identifier. 

##### recoverFromError

> Determines if *pipe* is going to be recovered or the whole *pipeline* is going to be restarted in case if *track* defined in `track` throws error. 

##### mode

> It is enum of type `Mode<SI, SO, TI, TO, DI, DO>` defining two modes: `simplex` and `duplex`. It specifies a way of communication between `source` and `PipeTrack` defined in `track`.
> 
> ###### simplex mode
> 
> This *mode* means that *source* will get `SO` response immediately before *track* starts processing of `TI` input value. 
> 
> **Warning**: `TI` must be at least a subtype of `SI` or the same as `SI`.
> 
> ---
> 
> ```swift
> case simplex(
>     instantOutput: SO? = nil,
>     intro: ((AsyncThrowingStream<SI, Error>) -> AsyncThrowingStream<TI, Error>),
>     outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error>)
> ```
> > Parameter `instantOutput` specifies value for instant output to the *source*. Parameter `intro` transforms `SI` value (received from *source*) into `TI` value which will be processed within *track*. Parameter `outro` transforms `TO` values (returned by *track*) into `DI` value which will be sent to *drain*.
>
> ---
> 
> ###### duplex mode
> 
> This *mode* means that *source* will get `SO` response only after *track* returns `TO` result value.
> 
> **Warning**: `TI` must be at least a subtype of `SI` or the same as `SI`.
> 
> **Warning**: `TO` must be at least a subtype of `SO` or the same as `SO`.
> 
> ---
> 
> ```swift
> case duplex(outro: (AsyncThrowingStream<TO, Error>) -> AsyncThrowingStream<DI, Error>)
> ```
> > Parameter `outro` transforms `TO` values (returned by *track*) into `DI` value which will be sent to *drain*.
>
> ---
> 

##### source

> It is *source* for input values of *track*. 

##### drain

> It is *drain* for output values of *track*. 

##### track

> Parameter `track` defines *track* (which is just a closure of `(I) async throws -> O` type) containing side effects and communicating with [`Interactor`](#interactor) of the [`Model`](#model).

---

```swift
public init(
    id: String,
    recoverFromError: Bool = true,
    policy: Policy,
    @escaping PipeTrack<Void, Void>)
```

> Creates an instance of `Pipe`.

#### Parameters:

##### id

> It is *pipe*'s identifier. 

##### recoverFromError

> Determines if *pipe* is going to be recovered or the whole *pipeline* is going to be restarted in case if *track* defined in `track` throws error. 

##### policy

> It is enum of type `Policy` defining two policies: `finite` and `infinite`.
> 
> ###### finite policy
> 
> This *policy* means that `track` will be executed finite number of times based on *policy*'s `count` parameter.
> 
> ###### infinite policy
> 
> This *policy* means that `track` will be executed infinite number of times. Execution cycle will be stopped only when the whole *pipeline* is stopped.

---
