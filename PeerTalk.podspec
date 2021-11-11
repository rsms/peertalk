Pod::Spec.new do |spec|
    spec.name     = 'PeerTalk'
    spec.version  = '0.1.0'
    spec.license  = { :type => 'MIT', :file => 'LICENSE.txt' }
    spec.homepage = 'http://rsms.me/peertalk/'
    spec.authors  = { 
        'Rasmus Andersson' => 'rasmus@notion.se',
        'Jonathan Dann' => 'jonathan@jonathandann.com'
    }
    spec.summary  = 'iOS and OS X Cocoa library for communicating over USB and TCP.'

    spec.source   = { :git => "https://github.com/rsms/PeerTalk.git", :tag => '0.1.0' }
    spec.source_files = 'Sources/peertalk/*.{h,m}'
    spec.ios.deployment_target = '14.0'
    spec.osx.deployment_target = '11.0'

    spec.description = "PeerTalk is a iOS and OS X Cocoa library for communicating over USB and TCP.\n\n                    Highlights:\n\n                    * Provides you with USB device attach/detach events and attached device's info\n                    * Can connect to TCP services on supported attached devices (e.g. an iPhone), bridging the communication over USB transport\n                    * Offers a higher-level API (PTChannel and PTProtocol) for convenient implementations.\n* Tested and designed for libdispatch (aka Grand Central Dispatch).\n"
    
    spec.swift_version = ['5.0']
end
