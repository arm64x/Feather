//
//  UIUserInterfaceStyle+allCases.swift
//  feather
//
//  Created by samara on 25.08.2024.
//

import UIKit
extension UIUserInterfaceStyle: @retroactive CaseIterable {
	public static var allCases: [UIUserInterfaceStyle] = [.unspecified, .dark, .light]
	var description: String {
		switch self {
		case .unspecified:
			return NSLocalizedString("SETTINGS_VIEW_CONTROLLER_CELL_DISPLAY_UI_MODE_SYSTEM", comment: "")
		case .light:
			return NSLocalizedString("SETTINGS_VIEW_CONTROLLER_CELL_DISPLAY_UI_MODE_LIGHT", comment: "")
		case .dark:
			return NSLocalizedString("SETTINGS_VIEW_CONTROLLER_CELL_DISPLAY_UI_MODE_DARK", comment: "")
		@unknown default:
			return NSLocalizedString("SETTINGS_VIEW_CONTROLLER_CELL_DISPLAY_UI_MODE_UNKNOWN", comment: "")
		}
	}
}
