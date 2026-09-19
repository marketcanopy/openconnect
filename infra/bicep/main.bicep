targetScope = 'resourceGroup'

@description('Azure region for the OpenConnector VM and its dedicated network.')
param location string

@description('Lowercase prefix used for Azure resource names.')
@minLength(3)
@maxLength(40)
param namePrefix string

@description('Dedicated VNet address space. It must not overlap with peered networks.')
param vnetAddressPrefix string = '10.253.0.0/16'

@description('Public IPv6 prefix allocated for this Azure VNet.')
param vnetIpv6AddressPrefix string

@description('Dedicated VM subnet address space inside the VNet.')
param subnetAddressPrefix string = '10.253.0.0/24'
param subnetIpv6AddressPrefix string

param adminUsername string
@secure()
param adminSshPublicKey string
param sshSourceCidr string
param vmSize string = 'Standard_D4s_v5'

param connectorHostname string
param acmeEmail string
param connectorImage string
@secure()
param connectorEncryptionKey string
@secure()
param connectorAdminToken string
@secure()
param connectorRuntimeToken string

var commonTags = {
  application: 'openconnector'
  service: 'ai-connectors'
  managedBy: 'openconnector'
}
var nsgName = '${namePrefix}-nsg'
var vnetName = '${namePrefix}-vnet'
var subnetName = '${namePrefix}-subnet'
var nicName = '${namePrefix}-nic'
var vmName = '${namePrefix}-vm'
var publicIpv4Name = '${namePrefix}-pip'
var publicIpv6Name = '${namePrefix}-pip6'
var publicDnsLabel = toLower(take('${namePrefix}-${uniqueString(resourceGroup().id)}', 63))
var computerName = take(replace(vmName, '-', ''), 15)

var cloudInitSource = loadTextContent('cloud-init.yml')
var composeBase64 = base64(loadTextContent('../docker-compose.yml'))
var caddyfileSource = loadTextContent('../Caddyfile')
var renderedCaddyfileBase64 = base64(replace(replace(caddyfileSource, '__ACME_EMAIL__', acmeEmail), '__CONNECTOR_HOSTNAME__', connectorHostname))
var cloudInit01 = replace(cloudInitSource, '__DOCKER_COMPOSE_BASE64__', composeBase64)
var cloudInit02 = replace(cloudInit01, '__CADDYFILE_BASE64__', renderedCaddyfileBase64)
var cloudInit03 = replace(cloudInit02, '__CONNECTOR_HOSTNAME__', connectorHostname)
var cloudInit04 = replace(cloudInit03, '__ACME_EMAIL__', acmeEmail)
var cloudInit05 = replace(cloudInit04, '__OPENCONNECTOR_ENCRYPTION_KEY__', connectorEncryptionKey)
var cloudInit06 = replace(cloudInit05, '__OPENCONNECTOR_ADMIN_TOKEN__', connectorAdminToken)
var renderedCloudInit = replace(cloudInit06, '__OPENCONNECTOR_RUNTIME_TOKEN__', connectorRuntimeToken)

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpIpv4'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '0.0.0.0/0'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHttpsIpv4'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '0.0.0.0/0'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHttpIpv6'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '::/0'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHttpsIpv6'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '::/0'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSshFromOperator'
        properties: {
          priority: 140
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: sshSourceCidr
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
        vnetIpv6AddressPrefix
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefixes: [
            subnetAddressPrefix
            subnetIpv6AddressPrefix
          ]
          networkSecurityGroup: {
            id: networkSecurityGroup.id
          }
        }
      }
    ]
  }
}

resource publicIpv4 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpv4Name
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 30
    dnsSettings: {
      domainNameLabel: publicDnsLabel
    }
  }
}

resource publicIpv6 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: publicIpv6Name
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv6'
    idleTimeoutInMinutes: 30
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  tags: commonTags
  properties: {
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipv4'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv4'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
          }
          publicIPAddress: {
            id: publicIpv4.id
          }
        }
      }
      {
        name: 'ipv6'
        properties: {
          primary: false
          privateIPAllocationMethod: 'Dynamic'
          privateIPAddressVersion: 'IPv6'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
          }
          publicIPAddress: {
            id: publicIpv6.id
          }
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: commonTags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
            deleteOption: 'Delete'
          }
        }
      ]
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      customData: base64(renderedCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          assessmentMode: 'ImageDefault'
          patchMode: 'ImageDefault'
        }
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output vmName string = virtualMachine.name
output vmResourceId string = virtualMachine.id
output publicIpv4Address string = publicIpv4.properties.ipAddress
output publicIpv4ResourceId string = publicIpv4.id
output publicIpv6Address string = publicIpv6.properties.ipAddress
output publicIpv6ResourceId string = publicIpv6.id
output publicDnsName string = publicIpv4.properties.dnsSettings.fqdn
output vnetName string = virtualNetwork.name
output subnetName string = subnetName
