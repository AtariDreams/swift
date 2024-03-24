// RUN: %target-swift-frontend -emit-sil -strict-concurrency=complete -enable-upcoming-feature RegionBasedIsolation -disable-availability-checking -verify %s -o /dev/null

// REQUIRES: concurrency
// REQUIRES: asserts

// This test validates how we handle partial applies that are isolated to a
// specific isolation domain (causing isolation crossings to occur).

////////////////////////
// MARK: Declarations //
////////////////////////

class NonSendableKlass {}

actor Custom {
  var x = NonSendableKlass()
}

@globalActor
struct CustomActor {
    static var shared: Custom {
        return Custom()
    }
}

func useValue<T>(_ t: T) {}
@MainActor func transferToMain<T>(_ t: T) {}
@CustomActor func transferToCustom<T>(_ t: T) {}

/////////////////
// MARK: Tests //
/////////////////

func doSomething(_ x: NonSendableKlass, _ y: NonSendableKlass) { }

actor ProtectsNonSendable {
  var ns: NonSendableKlass = .init()

  nonisolated func testParameter(_ ns: NonSendableKlass) async {
    self.assumeIsolated { isolatedSelf in
      isolatedSelf.ns = ns // expected-warning {{task-isolated value of type 'NonSendableKlass' transferred to actor-isolated context; later accesses to value could race}}
    }
  }

  // This should get the note since l is different from 'ns'.
  nonisolated func testParameterMergedIntoLocal(_ ns: NonSendableKlass) async {
    let l = NonSendableKlass()
    doSomething(l, ns)
    self.assumeIsolated { isolatedSelf in
      isolatedSelf.ns = l // expected-warning {{task-isolated value of type 'NonSendableKlass' transferred to actor-isolated context; later accesses to value could race}}
    }
  }

  nonisolated func testLocal() async {
    let l = NonSendableKlass()

    // This is safe since we do not reuse l.
    self.assumeIsolated { isolatedSelf in
      isolatedSelf.ns = l
    }
  }

  nonisolated func testLocal2() async {
    let l = NonSendableKlass()

    // This is not safe since we use l later.
    self.assumeIsolated { isolatedSelf in
      isolatedSelf.ns = l // expected-warning {{transferring 'l' may cause a race}}
      // expected-note @-1 {{disconnected 'l' is captured by actor-isolated closure. actor-isolated uses in closure may race against later nonisolated uses}}
    }

    useValue(l) // expected-note {{use here could race}}
  }
}

func normalFunc_testLocal_1() {
  let x = NonSendableKlass()
  let _ = { @MainActor in
    print(x)
  }
}

func normalFunc_testLocal_2() {
  let x = NonSendableKlass()
  let _ = { @MainActor in
    useValue(x) // expected-warning {{transferring 'x' may cause a race}}
    // expected-note @-1 {{disconnected 'x' is captured by main actor-isolated closure. main actor-isolated uses in closure may race against later nonisolated uses}}
  }
  useValue(x) // expected-note {{use here could race}}
}

// We error here since we are performing a double transfer.
//
// TODO: Add special transfer use so we can emit a double transfer error
// diagnostic.
func transferBeforeCaptureErrors() async {
  let x = NonSendableKlass()
  await transferToCustom(x) // expected-warning {{transferring 'x' may cause a race}}
  // expected-note @-1 {{transferring disconnected 'x' to global actor 'CustomActor'-isolated callee could cause races in between callee global actor 'CustomActor'-isolated and local nonisolated uses}}
  let _ = { @MainActor in // expected-note {{use here could race}}
    useValue(x)
  }
}
